import Foundation
@testable import BrimCore

enum CodexTests {
    static let canary = "SECRET-CODEX-CANARY"

    static func tokenCount(at: String, used: Double, minutes: Int = 300, resetsAt: Int, secondary: String = "") -> String {
        #"{"timestamp":"\#(at)","type":"event_msg","ordinal":4,"payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15},"model_context_window":272000},"rate_limits":{"limit_id":"codex","primary":{"used_percent":\#(used),"window_minutes":\#(minutes),"resets_at":\#(resetsAt)}\#(secondary),"plan_type":"pro"}}}"#
    }

    static func task(_ kind: String, at: String) -> String {
        #"{"timestamp":"\#(at)","type":"event_msg","ordinal":2,"payload":{"type":"\#(kind)","turn_id":"t1","last_agent_message":"\#(canary)"}}"#
    }

    static func meta(cwd: String) -> String {
        #"{"timestamp":"2026-09-24T10:00:00.000Z","type":"session_meta","ordinal":0,"payload":{"id":"x","cwd":"\#(cwd)","originator":"codex_cli_rs","base_instructions":{"text":"\#(canary)"}}}"#
    }

    static let reset = Int(date("2026-09-24T14:00:00Z").timeIntervalSince1970)

    static let suite = TestSuite("Codex", [
        test("reads the server's rate limits") {
            let entry = CodexRolloutParser.parse(Data(tokenCount(at: "2026-09-24T11:00:00.000Z", used: 21, resetsAt: reset).utf8))
            guard case .rateLimits(let limits)? = entry else { return expect(false, "no limits parsed") }
            expectEqual(limits.primary?.usedPercent, 21)
            expectEqual(limits.primary?.windowMinutes, 300)
            expectEqual(limits.primary?.resetsAt, date("2026-09-24T14:00:00Z"))
            expectEqual(limits.planType, "pro")
        },
        test("messages and instructions are never read") {
            let taskEntry = CodexRolloutParser.parse(Data(task("task_complete", at: "2026-09-24T11:00:00.000Z").utf8))
            expect(!"\(String(describing: taskEntry))".contains(canary))
            let metaEntry = CodexRolloutParser.parse(Data(meta(cwd: "/Users/me/api").utf8))
            expectEqual(metaEntry, .sessionMeta(cwd: "/Users/me/api", originator: "codex_cli_rs"))
            expectNil(CodexRolloutParser.parse(Data(#"{"type":"response_item","payload":{"type":"message"}}"#.utf8)))
        },
        test("windows are labelled by their length") {
            expectEqual(CodexProvider.label(minutes: 300, fallback: "x"), "5-hour limit")
            expectEqual(CodexProvider.label(minutes: 10_080, fallback: "x"), "Weekly limit")
            expectEqual(CodexProvider.label(minutes: nil, fallback: "fallback"), "fallback")
        },
        test("figures are official until the window rolls over") {
            let limits = CodexRateLimits(timestamp: date("2026-09-24T11:00:00Z"),
                                         primary: .init(usedPercent: 21, windowMinutes: 300, resetsAt: date("2026-09-24T14:00:00Z")),
                                         secondary: .init(usedPercent: 34, windowMinutes: 10_080, resetsAt: date("2026-09-28T00:00:00Z")),
                                         planType: "pro")
            let live = CodexProvider.windows(from: limits, now: date("2026-09-24T12:00:00Z"))
            expectEqual(live.map(\.fidelity), [.official, .official])
            expectApprox(live[0].usedFraction, 0.21)

            let rolled = CodexProvider.windows(from: limits, now: date("2026-09-24T15:00:00Z"))
            expectEqual(rolled[0].usedFraction, 0)
            expectEqual(rolled[0].fidelity, .derived)
            expectEqual(rolled[0].resetsAt, date("2026-09-24T19:00:00Z"))
            expectEqual(rolled[1].fidelity, .official)
        },
        test("session state follows the last task event") {
            let now = date("2026-09-24T12:00:00Z")
            typealias Trace = CodexRolloutScanner.SessionTrace
            let traces: [String: Trace] = [
                "a": Trace(cwd: "/x/api", originator: nil, lastActivity: ("task_started", now.addingTimeInterval(-30)), modified: now),
                "b": Trace(cwd: "/x/web", originator: nil, lastActivity: ("task_complete", now.addingTimeInterval(-3)), modified: now),
                "c": Trace(cwd: "/x/old", originator: nil, lastActivity: ("task_complete", now.addingTimeInterval(-3)),
                           modified: now.addingTimeInterval(-3600)),
                "d": Trace(cwd: "/x/ask", originator: "Codex Desktop", lastActivity: ("exec_approval_request", now), modified: now),
            ]
            let sessions = Dictionary(uniqueKeysWithValues: CodexProvider.sessions(from: traces, providerID: "codex", now: now)
                .map { ($0.name, $0) })
            expectEqual(sessions["api"]?.state, .busy)
            expectEqual(sessions["web"]?.state, .finished)
            expectNil(sessions["old"])
            expectEqual(sessions["ask"]?.state, .waiting)
            expectEqual(sessions["ask"]?.detail, "Codex app · ask")
        },
        test("the scanner keeps the newest limits across files") {
            try await withTemporaryDirectory { root in
                let codex = root.appendingPathComponent(".codex")
                let day = codex.appendingPathComponent("sessions/2026/09/24")
                let now = Date()
                let stamp = { (offset: TimeInterval) in ISO8601DateFormatter().string(from: now.addingTimeInterval(offset)) }
                write([meta(cwd: "/x/api"), tokenCount(at: stamp(-600), used: 10, resetsAt: reset)].joined(separator: "\n") + "\n",
                      to: day.appendingPathComponent("rollout-a.jsonl"))
                write([tokenCount(at: stamp(-60), used: 40, resetsAt: reset), task("task_started", at: stamp(-30))]
                    .joined(separator: "\n") + "\n", to: day.appendingPathComponent("rollout-b.jsonl"))
                let scanner = CodexRolloutScanner(files: LocalFileAccess(allowedRoots: [codex.appendingPathComponent("sessions")]),
                                                  codexDirectory: codex)
                scanner.scan(now: now)
                expectEqual(try unwrap(scanner.latestLimits).primary?.usedPercent, 40)
                expectEqual(scanner.traces["rollout-a"]?.cwd, "/x/api")
                expectEqual(scanner.traces["rollout-b"]?.lastActivity?.kind, "task_started")
            }
        },
    ])
}

enum LocalRuntimeTests {
    static let psJSON = """
    {"models":[{"name":"llama3.2:3b","model":"llama3.2:3b","size":2019393189,"digest":"a80c4f","details":{"parent_model":"","format":"gguf","family":"llama","parameter_size":"3.2B","quantization_level":"Q4_K_M"},"expires_at":"2026-09-24T12:04:31.837533-07:00","size_vram":2019393189,"context_length":4096}]}
    """

    static let suite = TestSuite("Local runtimes", [
        test("Ollama's loaded models decode") {
            let models = try unwrap(OllamaResponse.loadedModels(from: Data(psJSON.utf8)))
            expectEqual(models.count, 1)
            expectEqual(models[0].name, "llama3.2:3b")
            expectEqual(models[0].contextLength, 4096)
            expectEqual(models[0].quantization, "Q4_K_M")
            expectEqual(models[0].expiresAt.map { Int($0.timeIntervalSince1970) }, Int(date("2026-09-24T19:04:31Z").timeIntervalSince1970))
            expectNil(OllamaResponse.loadedModels(from: Data("not json".utf8)))
        },
        test("Ollama's snapshot is a local reading with no quota") {
            let models = try unwrap(OllamaResponse.loadedModels(from: Data(psJSON.utf8)))
            let s = OllamaProvider.snapshot(id: "ollama", models: models, requests: nil, now: date("2026-09-24T19:00:00Z"),
                                            physicalMemory: 32 << 30)
            expectEqual(s.fidelity, .local)
            expectEqual(s.cellLabel, "1 model")
            expectEqual(s.headline?.id, "memory")
            expect(s.windows.contains { $0.id == "model.llama3.2:3b" && $0.detail?.contains("100% GPU") == true })
            let idle = OllamaProvider.snapshot(id: "ollama", models: [], requests: nil, now: Date(), physicalMemory: 1)
            expectEqual(idle.cellLabel, "Idle")
            expect(!idle.hasReading)
        },
        test("access-log lines give counts and timings, never bodies") {
            let line = #"[GIN] 2026/09/24 - 14:33:31 | 200 |  3.123456789s |       127.0.0.1 | POST     "/api/chat""#
            let request = try unwrap(OllamaServerLog.parse(line, timeZone: TimeZone(identifier: "UTC")!))
            expectEqual(request.status, 200)
            expectApprox(request.duration, 3.123456789)
            expectEqual(request.path, "/api/chat")
            expectEqual(request.at, date("2026-09-24T14:33:31Z"))
            expectNil(OllamaServerLog.parse("time=2026-09-24 level=INFO msg=\"loading model\""))
        },
        test("Go durations") {
            expectApprox(OllamaServerLog.goDuration("850µs"), 0.00085)
            expectApprox(OllamaServerLog.goDuration("12.5ms"), 0.0125)
            expectApprox(OllamaServerLog.goDuration("1m4.5s"), 64.5)
            expectApprox(OllamaServerLog.goDuration("1h2m3s"), 3723)
            expectNil(OllamaServerLog.goDuration("soon"))
        },
        test("LM Studio's model list decodes, loaded and not") {
            let json = """
            {"object":"list","data":[{"id":"qwen3-8b","object":"model","type":"llm","publisher":"q","arch":"qwen3","quantization":"4bit","state":"loaded","max_context_length":32768,"loaded_context_length":8192},{"id":"nomic-embed","type":"embeddings","state":"loaded"},{"id":"other","type":"llm","state":"not-loaded"}]}
            """
            let models = try unwrap(LMStudioResponse.models(from: Data(json.utf8)))
            expectEqual(models.count, 3)
            expectEqual(models[0].contextLength, 8192)
            let s = LMStudioProvider.snapshot(id: "lmStudio", models: models, summary: nil, now: Date())
            expectEqual(s.cellLabel, "1 model")
            expectEqual(s.windows.map(\.id), ["model.qwen3-8b"])
        },
        test("LM Studio's log yields numbers and never text") {
            let log = """
            [2026-09-24 00:35:38][INFO][qwen3-8b] Running chat completion on conversation with 1 messages.
            [2026-09-24 00:35:39][INFO][qwen3-8b] Prompt processing progress: 100.0%
            [2026-09-24 00:35:56][INFO][qwen3-8b] Generated prediction: {
              "id": "chatcmpl-1",
              "model": "qwen3-8b",
              "choices": [
                {
                  "message": {
                    "role": "assistant",
                    "content": "SECRET-REPLY-CANARY",
                    "reasoning_content": "SECRET-REASONING-CANARY"
                  }
                }
              ],
              "usage": {
                "prompt_tokens": 66,
                "completion_tokens": 300,
                "total_tokens": 366,
                "completion_tokens_details": {
                  "reasoning_tokens": 300
                }
              },
              "stats": {
                "tokens_per_second": 17.9289,
                "time_to_first_token": 1.162136,
                "stop_reason": "maxPredictedTokensReached"
              }
            }
            [2026-09-24 00:40:00][INFO][LM STUDIO SERVER] Success! HTTP server listening on port 1234
            """
            let summary = LMStudioServerLog.parse(log.components(separatedBy: "\n"), timeZone: TimeZone(identifier: "UTC")!)
            expectEqual(summary.requests["qwen3-8b"], 1)
            let last = try unwrap(summary.last(for: "qwen3-8b"))
            expectEqual(last.promptTokens, 66)
            expectEqual(last.completionTokens, 300)
            expectApprox(last.tokensPerSecond, 17.9289)
            expectEqual(summary.tokensToday(for: "qwen3-8b"), 366)
            expect(!"\(summary)".contains("CANARY"))

            let model = LMStudioModel(id: "qwen3-8b", loadedContextLength: 8192)
            let s = LMStudioProvider.snapshot(id: "lmStudio", models: [model], summary: summary, now: Date())
            expectApprox(s.usedFraction, 366.0 / 8192.0)
            expect(s.windows[0].detail?.contains("18 tok/s") == true, s.windows[0].detail ?? "")
        },
    ])
}

enum ManualTests {
    static let now = date("2026-09-24T12:00:00Z")   // Thursday

    static let suite = TestSuite("Manual providers", [
        test("schedules find the next reset") {
            expectEqual(ResetSchedule.daily(hour: 9, minute: 0).nextReset(after: now, calendar: utc), date("2026-09-25T09:00:00Z"))
            expectEqual(ResetSchedule.daily(hour: 15, minute: 30).nextReset(after: now, calendar: utc), date("2026-09-24T15:30:00Z"))
            expectEqual(ResetSchedule.weekly(weekday: 2, hour: 0, minute: 0).nextReset(after: now, calendar: utc),
                        date("2026-09-28T00:00:00Z"))
            expectEqual(ResetSchedule.monthly(day: 1, hour: 0, minute: 0).nextReset(after: now, calendar: utc),
                        date("2026-10-01T00:00:00Z"))
            expectEqual(ResetSchedule.everyHours(5, anchor: date("2026-09-24T01:00:00Z")).nextReset(after: now, calendar: utc),
                        date("2026-09-24T16:00:00Z"))
            expectNil(ResetSchedule.none.nextReset(after: now))
            expectNil(ResetSchedule.once(date("2026-09-01T00:00:00Z")).nextReset(after: now))
        },
        test("a day past the end of a month lands on its last day") {
            let jan31 = date("2027-01-31T12:00:00Z")
            expectEqual(ResetSchedule.monthly(day: 31, hour: 0, minute: 0).nextReset(after: jan31, calendar: utc),
                        date("2027-02-28T00:00:00Z"))
        },
        test("usage rolls over once a reset passes") {
            var config = ManualProviderConfig(name: "Cursor", windows: [
                ManualWindow(id: "w", label: "Requests", limit: 500, used: 260, schedule: .daily(hour: 0, minute: 0),
                             lastReset: date("2026-09-23T08:00:00Z")),
            ])
            let rolled = try unwrap(config.rolledOver(now: now, calendar: utc))
            expectEqual(rolled.windows[0].used, 0)
            expectEqual(rolled.windows[0].lastReset, now)
            config.windows[0].lastReset = date("2026-09-24T01:00:00Z")
            expectNil(config.rolledOver(now: now, calendar: utc))
        },
        test("the snapshot is exact arithmetic on what was entered") {
            let config = ManualProviderConfig(name: "Cursor", windows: [
                ManualWindow(id: "w", label: "Premium requests", limit: 500, used: 260, unit: "requests",
                             schedule: .monthly(day: 1, hour: 0, minute: 0)),
            ])
            let s = ManualProvider.snapshot(config: config, now: now)
            expectEqual(s.fidelity, .manual)
            expectApprox(s.usedFraction, 0.52)
            expectEqual(s.windows[0].detail, "260 of 500 requests")
            expectEqual(s.glyph, .monogram("C"))
            expect(s.windows[0].resetsAt != nil)
        },
        test("no limit means no percentage, and no windows means a status") {
            let noLimit = ManualWindow(label: "Credits", limit: 0, used: 5)
            expectNil(noLimit.usedFraction)
            let empty = ManualProvider.snapshot(config: ManualProviderConfig(name: "X"), now: now)
            expect(empty.status.isProblem)
        },
    ])
}

enum DemoTests {
    static let suite = TestSuite("Demo data", [
        test("is deterministic for a given moment") {
            let moment = date("2026-09-24T12:00:00Z")
            expectEqual(DemoData.snapshots(now: moment), DemoData.snapshots(now: moment))
            expectEqual(DemoData.sessions(now: moment), DemoData.sessions(now: moment))
        },
        test("matches the design frame's three readings") {
            let readings = DemoData.snapshots(now: Date()).prefix(3).map(\.headlineText)
            expectEqual(Array(readings), ["73%", "21%", "52%"])
        },
        test("sessions cycle through every state") {
            var seen = Set<SessionState>()
            let base = date("2026-09-24T12:00:00Z")
            for second in 0..<60 {
                for session in DemoData.sessions(now: base.addingTimeInterval(Double(second))) { seen.insert(session.state) }
            }
            expect(seen.isSuperset(of: [.busy, .waiting, .finished, .idle]))
        },
    ])
}
