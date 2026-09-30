import Foundation
@testable import BrimCore

/// Synthetic transcript lines. The message text is a canary: nothing Brim
/// produces may ever contain it.
enum ClaudeFixtures {
    static let canary = "SECRET-PROMPT-CANARY"

    static func assistant(id: String, request: String, at: String, input: Int = 100, output: Int = 50,
                          cacheWrite: Int = 0, cacheRead: Int = 0, model: String = "claude-opus-5-5") -> String {
        #"{"parentUuid":"x","isSidechain":false,"type":"assistant","timestamp":"\#(at)","requestId":"\#(request)","sessionId":"s1","cwd":"/Users/me/brim","message":{"id":"\#(id)","model":"\#(model)","role":"assistant","type":"message","content":[{"type":"text","text":"\#(canary) with \"usage\": {nested}"}],"stop_reason":"end_turn","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":\#(cacheWrite),"cache_read_input_tokens":\#(cacheRead),"service_tier":"standard"}}}"#
    }

    static func user(at: String) -> String {
        #"{"type":"user","timestamp":"\#(at)","message":{"role":"user","content":"\#(canary) please fix the usage page"}}"#
    }

    static func limit(at: String, type: String = "five_hour", resetsAt: Date) -> String {
        #"{"type":"assistant","timestamp":"\#(at)","isApiErrorMessage":true,"error":"rate_limit","apiErrorStatus":429,"quotaLimits":{"status":"rejected","resetsAt":\#(Int(resetsAt.timeIntervalSince1970)),"rateLimitType":"\#(type)","overageStatus":"rejected"},"message":{"role":"assistant","content":[{"type":"text","text":"Claude AI usage limit reached"}]}}"#
    }

    static func entries(_ lines: [String]) -> [ClaudeLogEntry] {
        lines.compactMap { ClaudeTranscriptParser.parse(Data($0.utf8)) }
    }

    static func ledger(_ lines: [String]) -> ClaudeUsageLedger {
        let ledger = ClaudeUsageLedger()
        entries(lines).forEach(ledger.ingest)
        return ledger
    }
}

enum ClaudeParsingTests {
    typealias F = ClaudeFixtures

    static let suite = TestSuite("Claude transcripts", [
        test("reads token counts and nothing else") {
            let entries = F.entries([F.assistant(id: "msg_1", request: "req_1", at: "2026-09-24T10:15:00.123Z",
                                                 input: 10, output: 20, cacheWrite: 30, cacheRead: 40)])
            guard case .usage(let event)? = entries.first else { return expect(false, "no usage parsed") }
            expectEqual(event.tokens, TokenCounts(input: 10, output: 20, cacheCreation: 30, cacheRead: 40))
            expectEqual(event.model, "claude-opus-5-5")
            expectApprox(event.timestamp.timeIntervalSince1970, date("2026-09-24T10:15:00Z").timeIntervalSince1970 + 0.123,
                         tolerance: 0.0005)
            expect(!"\(event)".contains(F.canary), "parsed event must not carry message text")
        },
        test("user lines and lines without usage are skipped") {
            expect(F.entries([F.user(at: "2026-09-24T10:00:00.000Z")]).isEmpty)
            expect(F.entries(["not json", "{}", #"{"type":"assistant"}"#]).isEmpty)
        },
        test("records Anthropic's rate-limit rejections") {
            let reset = date("2026-09-24T15:00:00Z")
            let entries = F.entries([F.limit(at: "2026-09-24T12:30:00.000Z", resetsAt: reset)])
            guard case .limit(let event)? = entries.first else { return expect(false, "no limit parsed") }
            expectEqual(event.type, "five_hour")
            expectEqual(event.resetsAt, reset)
            expectEqual(event.status, "rejected")
        },
        test("one response logged on several lines counts once") {
            let ledger = F.ledger([
                F.assistant(id: "msg_1", request: "req_1", at: "2026-09-24T10:00:00.000Z", output: 5),
                F.assistant(id: "msg_1", request: "req_1", at: "2026-09-24T10:00:01.000Z", output: 50),
                F.assistant(id: "msg_2", request: "req_2", at: "2026-09-24T10:01:00.000Z", output: 7),
            ])
            expectEqual(ledger.usage.count, 2)
            expectEqual(ledger.usage["msg_1|req_1"]?.tokens.output, 50)
        },
        test("repeated rejections of one window keep the first") {
            let reset = date("2026-09-24T15:00:00Z")
            let ledger = F.ledger([
                F.limit(at: "2026-09-24T12:31:00.000Z", resetsAt: reset),
                F.limit(at: "2026-09-24T12:30:00.000Z", resetsAt: reset),
            ])
            expectEqual(ledger.limits.count, 1)
            expectEqual(ledger.limits.first?.timestamp, date("2026-09-24T12:30:00Z"))
        },
        test("weighted tokens discount cache reads and weight output") {
            let tokens = TokenCounts(input: 100, output: 10, cacheCreation: 40, cacheRead: 1000)
            expectApprox(tokens.weighted, 100 + 50 + 50 + 100)
            expectEqual(tokens.total, 1150)
        },
    ])
}

enum ClaudeEstimatorTests {
    typealias F = ClaudeFixtures
    static let now = date("2026-09-24T12:40:00Z")

    static func events(_ times: [String], input: Int = 1000) -> [UsageEvent] {
        F.ledger(times.enumerated().map { F.assistant(id: "m\($0.offset)", request: "r\($0.offset)", at: $0.element,
                                                      input: input, output: 0) }).sortedUsage
    }

    static let suite = TestSuite("Claude estimates", [
        test("a block opens with its first response and runs five hours") {
            // Not on the hour: Anthropic's windows start with the request that opens them.
            let blocks = ClaudeUsageEstimator.blocks(from: events(["2026-09-24T10:17:00.000Z", "2026-09-24T12:30:00.000Z"]))
            expectEqual(blocks.count, 1)
            expectEqual(blocks[0].start, date("2026-09-24T10:17:00Z"))
            expectEqual(blocks[0].end, date("2026-09-24T15:17:00Z"))
            expectEqual(blocks[0].responses, 2)
        },
        test("activity after the block ends opens a new one") {
            let blocks = ClaudeUsageEstimator.blocks(from: events([
                "2026-09-24T01:10:00.000Z", "2026-09-24T06:05:00.000Z", "2026-09-24T06:15:00.000Z",
            ]))
            expectEqual(blocks.map(\.start), [date("2026-09-24T01:10:00Z"), date("2026-09-24T06:15:00Z")])
            expectEqual(blocks.map(\.responses), [2, 1])
        },
        test("a reset Anthropic reported pins its window and cuts short a guess that would overlap it") {
            let blocks = ClaudeUsageEstimator.blocks(
                from: events(["2026-09-24T09:00:00.000Z", "2026-09-24T10:30:00.000Z", "2026-09-24T14:59:00.000Z"]),
                knownEnds: [date("2026-09-24T15:00:00Z")])
            expectEqual(blocks.map(\.start), [date("2026-09-24T09:00:00Z"), date("2026-09-24T10:00:00Z")])
            expectEqual(blocks.map(\.end), [date("2026-09-24T10:00:00Z"), date("2026-09-24T15:00:00Z")])
            expectEqual(blocks.map(\.responses), [1, 2])
        },
        test("without a budget the session shows tokens but no percentage") {
            let windows = ClaudeUsageEstimator.windows(events: events(["2026-09-24T10:17:00.000Z"]), limits: [],
                                                       now: now, budgets: .init())
            let session = windows.first { $0.id == "session" }
            expectNil(session?.usedFraction ?? nil)
            expectEqual(session?.resetsAt, date("2026-09-24T15:17:00Z"))
            expectEqual(session?.fidelity, .derived)
            expect(session?.detail?.contains("1K tokens") == true, "\(session?.detail ?? "")")
        },
        test("a budget turns tokens into an estimate, capped short of spent") {
            var budgets = ClaudeUsageEstimator.Budgets()
            budgets.session = 4000
            let windows = ClaudeUsageEstimator.windows(events: events(["2026-09-24T10:17:00.000Z", "2026-09-24T11:00:00.000Z"]),
                                                       limits: [], now: now, budgets: budgets)
            expectApprox(windows.first { $0.id == "session" }?.usedFraction, 0.5)
            budgets.session = 100
            let capped = ClaudeUsageEstimator.windows(events: events(["2026-09-24T10:17:00.000Z"]), limits: [],
                                                      now: now, budgets: budgets)
            expectApprox(capped.first { $0.id == "session" }?.usedFraction, ClaudeUsageEstimator.derivedCeiling)
        },
        test("an active rejection is an official 100% until its reset") {
            let reset = date("2026-09-24T15:00:00Z")
            let ledger = F.ledger([F.limit(at: "2026-09-24T12:30:00.000Z", resetsAt: reset)])
            let windows = ClaudeUsageEstimator.windows(events: [], limits: ledger.limits, now: now, budgets: .init())
            let session = windows.first { $0.id == "session" }
            expectEqual(session?.usedFraction, 1)
            expectEqual(session?.fidelity, .official)
            expectEqual(session?.resetsAt, reset)
            let after = ClaudeUsageEstimator.windows(events: [], limits: ledger.limits,
                                                     now: reset.addingTimeInterval(60), budgets: .init())
            expectEqual(after.first { $0.id == "session" }?.fidelity, .derived)
        },
        test("calibration measures what was spent when the limit hit") {
            let reset = date("2026-09-24T15:00:00Z")
            let ledger = F.ledger([
                F.assistant(id: "a", request: "1", at: "2026-09-24T10:30:00.000Z", input: 3000, output: 0),
                F.assistant(id: "b", request: "2", at: "2026-09-24T12:00:00.000Z", input: 2000, output: 0),
                F.limit(at: "2026-09-24T12:30:00.000Z", resetsAt: reset),
                F.assistant(id: "c", request: "3", at: "2026-09-24T09:00:00.000Z", input: 99_999, output: 0),
            ])
            let calibration = ClaudeUsageEstimator.calibration(events: ledger.sortedUsage, limits: ledger.limits,
                                                               coverageStart: date("2026-09-20T00:00:00Z"))
            expectApprox(calibration.sessionBudget, 5000)
            expectEqual(calibration.sessionMeasuredAt, date("2026-09-24T12:30:00Z"))
        },
        test("calibration skips windows the logs do not cover") {
            let ledger = F.ledger([F.limit(at: "2026-09-24T12:30:00.000Z", resetsAt: date("2026-09-24T15:00:00Z"))])
            let calibration = ClaudeUsageEstimator.calibration(events: ledger.sortedUsage, limits: ledger.limits,
                                                               coverageStart: date("2026-09-24T11:00:00Z"))
            expectNil(calibration.sessionBudget)
        },
        test("a user budget outranks a measured one") {
            var settings = ClaudeSettings()
            let measured = ClaudeCalibration(sessionBudget: 9000, sessionMeasuredAt: now)
            expectEqual(ClaudeUsageEstimator.budgets(settings: settings, calibration: measured).session, 9000)
            settings.sessionBudget = 1234
            expectEqual(ClaudeUsageEstimator.budgets(settings: settings, calibration: measured).session, 1234)
            settings.sessionBudget = nil
            settings.calibrateFromLimitHits = false
            expectNil(ClaudeUsageEstimator.budgets(settings: settings, calibration: measured).session)
        },
        test("weekly resets are projected from a past weekly rejection") {
            let anchor = date("2026-09-10T08:00:00Z")
            expectEqual(ClaudeUsageEstimator.nextWeeklyReset(anchors: [anchor], now: now), date("2026-09-24T08:00:00Z").addingTimeInterval(7 * 86_400))
            expectNil(ClaudeUsageEstimator.nextWeeklyReset(anchors: [], now: now))
        },
        test("newer calibrations replace older ones") {
            let old = ClaudeCalibration(sessionBudget: 1, sessionMeasuredAt: date("2026-09-01T00:00:00Z"))
            let new = ClaudeCalibration(sessionBudget: 2, sessionMeasuredAt: date("2026-09-20T00:00:00Z"))
            expectEqual(old.updated(with: new).sessionBudget, 2)
            expectEqual(new.updated(with: old).sessionBudget, 2)
            expectEqual(new.updated(with: ClaudeCalibration()).sessionBudget, 2)
        },
        test("a measurement of the same moment from fuller logs replaces the stored one") {
            // The first pass over a huge log once measured from half of it, and
            // a strictly-newer rule kept that figure for good.
            let at = date("2026-09-24T14:23:53Z")
            let partial = ClaudeCalibration(sessionBudget: 5_850_000, sessionMeasuredAt: at)
            let full = ClaudeCalibration(sessionBudget: 8_600_000, sessionMeasuredAt: at)
            expectEqual(partial.updated(with: full).sessionBudget, 8_600_000)
        },
    ])
}

enum ClaudeScannerTests {
    typealias F = ClaudeFixtures

    static let suite = TestSuite("Claude scanner", [
        test("reads new lines incrementally and waits for half-written ones") {
            try await withTemporaryDirectory { root in
                let claude = root.appendingPathComponent(".claude")
                let file = claude.appendingPathComponent("projects/-Users-me-brim/s1.jsonl")
                let now = Date()
                let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
                write(F.assistant(id: "a", request: "1", at: stamp) + "\n" + #"{"type":"assistant","time"#, to: file)
                let access = LocalFileAccess(allowedRoots: [claude.appendingPathComponent("projects")])
                let scanner = ClaudeTranscriptScanner(files: access, claudeDirectory: claude)
                scanner.scan(now: now)
                expectEqual(scanner.ledger.usage.count, 1)

                let handle = try FileHandle(forWritingTo: file)
                handle.seekToEndOfFile()
                handle.write(Data(("\n" + F.assistant(id: "b", request: "2", at: stamp) + "\n").utf8))
                try handle.close()
                scanner.scan(now: now)
                expectEqual(scanner.ledger.usage.count, 2)
                expectNotNil(scanner.lastWrite(sessionID: "s1"))
            }
        },
        test("one pass reads a log bigger than a single read, to the end") {
            await withTemporaryDirectory { root in
                let claude = root.appendingPathComponent(".claude")
                let file = claude.appendingPathComponent("projects/-Users-me-brim/s1.jsonl")
                let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
                let lines = (0..<12).map { F.assistant(id: "m\($0)", request: "r\($0)", at: stamp) }
                write(lines.joined(separator: "\n") + "\n", to: file)
                let access = LocalFileAccess(allowedRoots: [claude.appendingPathComponent("projects")])
                let scanner = ClaudeTranscriptScanner(files: access, claudeDirectory: claude,
                                                      chunkBytes: lines[0].utf8.count * 2 + 10)
                scanner.scan(now: Date())
                expectEqual(scanner.ledger.usage.count, 12)
            }
        },
    ])
}

enum ClaudeSessionTests {
    static func record(pid: Int, status: String, cwd: String = "/Users/me/brim", name: String = "Fix the login bug",
                       startedAt: Double = 1_790_000_000_000, changed: Double = 1_790_000_100_000,
                       extra: String = "") -> String {
        #"{"pid":\#(pid),"sessionId":"s\#(pid)","cwd":"\#(cwd)","startedAt":\#(Int(startedAt)),"procStart":"Thu Sep 24 13:30:00 2026","version":"2.1.280","kind":"interactive","entrypoint":"cli","name":"\#(name)","nameSource":"derived","status":"\#(status)","updatedAt":\#(Int(changed)),"statusUpdatedAt":\#(Int(changed))\#(extra)}"#
    }

    static func monitor(in root: URL, alive: Set<Int32>, started: Date? = nil) -> ClaudeSessionMonitor {
        let claude = root.appendingPathComponent(".claude")
        let access = LocalFileAccess(allowedRoots: [claude.appendingPathComponent("sessions")])
        let probe = ProcessProbe(isAlive: { alive.contains($0) },
                                 startTime: { _ in started })
        return ClaudeSessionMonitor(files: access, claudeDirectory: claude, probe: probe)
    }

    static let suite = TestSuite("Claude sessions", [
        test("maps Claude Code's status words") {
            let data = { (status: String) in Data(record(pid: 1, status: status).utf8) }
            expectEqual(ClaudeSessionRecord(json: data("busy"))?.state, .busy)
            expectEqual(ClaudeSessionRecord(json: data("waiting"))?.state, .waiting)
            expectEqual(ClaudeSessionRecord(json: data("idle"))?.state, .idle)
            expectEqual(ClaudeSessionRecord(json: data("something-new"))?.state, .idle)
            expectNil(ClaudeSessionRecord(json: Data(#"{"cwd":"/x"}"#.utf8)))
        },
        test("dead processes and recycled pids are dropped") {
            await withTemporaryDirectory { root in
                let dir = root.appendingPathComponent(".claude/sessions")
                write(record(pid: 10, status: "busy"), to: dir.appendingPathComponent("10.json"))
                write(record(pid: 11, status: "busy"), to: dir.appendingPathComponent("11.json"))
                let now = Date(timeIntervalSince1970: 1_790_000_200)
                let live = monitor(in: root, alive: [10], started: Date(timeIntervalSince1970: 1_790_000_000))
                expectEqual(live.sessions(now: now, providerID: "claudeCode", showTitles: false, lastWrite: { _ in now })
                    .map(\.processID), [10])
                let recycled = monitor(in: root, alive: [10, 11], started: Date(timeIntervalSince1970: 1_700_000_000))
                expect(recycled.sessions(now: now, providerID: "claudeCode", showTitles: false, lastWrite: { _ in now }).isEmpty)
            }
        },
        test("titles are hidden unless asked for") {
            await withTemporaryDirectory { root in
                write(record(pid: 12, status: "idle"), to: root.appendingPathComponent(".claude/sessions/12.json"))
                let now = Date(timeIntervalSince1970: 1_790_000_200)
                let m = monitor(in: root, alive: [12])
                expectEqual(m.sessions(now: now, providerID: "c", showTitles: false, lastWrite: { _ in nil }).first?.name, "brim")
                expectEqual(m.sessions(now: now, providerID: "c", showTitles: true, lastWrite: { _ in nil }).first?.name,
                            "Fix the login bug")
                expectEqual(m.sessions(now: now, providerID: "c", showTitles: false, lastWrite: { _ in nil }).first?.detail,
                            "Terminal · brim")
            }
        },
        test("leaving busy shows as finished for a moment") {
            await withTemporaryDirectory { root in
                let file = root.appendingPathComponent(".claude/sessions/13.json")
                let m = monitor(in: root, alive: [13])
                let now = Date(timeIntervalSince1970: 1_790_000_200)
                write(record(pid: 13, status: "busy"), to: file)
                expectEqual(m.sessions(now: now, providerID: "c", showTitles: false, lastWrite: { _ in now }).first?.state, .busy)
                write(record(pid: 13, status: "idle"), to: file)
                expectEqual(m.sessions(now: now.addingTimeInterval(2), providerID: "c", showTitles: false,
                                       lastWrite: { _ in nil }).first?.state, .finished)
                expectEqual(m.sessions(now: now.addingTimeInterval(4), providerID: "c", showTitles: false,
                                       lastWrite: { _ in nil }).first?.state, .finished)
                expectEqual(m.sessions(now: now.addingTimeInterval(30), providerID: "c", showTitles: false,
                                       lastWrite: { _ in nil }).first?.state, .idle)
            }
        },
        test("a working session that has gone quiet is stale") {
            await withTemporaryDirectory { root in
                write(record(pid: 14, status: "busy"), to: root.appendingPathComponent(".claude/sessions/14.json"))
                let m = monitor(in: root, alive: [14])
                let now = Date(timeIntervalSince1970: 1_790_000_100 + 3600)
                expectEqual(m.sessions(now: now, providerID: "c", showTitles: false, lastWrite: { _ in nil }).first?.state, .stale)
                expectEqual(m.sessions(now: now, providerID: "c", showTitles: false,
                                       lastWrite: { _ in now.addingTimeInterval(-60) }).first?.state, .busy)
            }
        },
        test("Brim's own /usage runs are not listed") {
            await withTemporaryDirectory { root in
                write(record(pid: 15, status: "busy", cwd: "/tmp/brim-scratch"),
                      to: root.appendingPathComponent(".claude/sessions/15.json"))
                let m = monitor(in: root, alive: [15])
                m.ignoredDirectories = ["/tmp/brim-scratch"]
                expect(m.sessions(now: Date(), providerID: "c", showTitles: false, lastWrite: { _ in nil }).isEmpty)
            }
        },
    ])
}

enum ClaudeCLITests {
    static let now = date("2026-09-24T12:00:00Z")
    static let sample = """
    Plan: Max (20x)

    Current session: 38% used · resets Sep 24 at 2:59pm (UTC)
    Current week (all models): 4% used · resets Sep 28 at 5:59am (UTC)
    Current week (Opus): 12% used · resets Sep 28 at 6am (UTC)

    Most of your usage came from long sessions in one project.
    """

    static let suite = TestSuite("Claude /usage", [
        test("reads the session and weekly lines") {
            let reading = try ClaudeUsageCLI.parse(sample, now: now)
            expectEqual(reading.windows.map(\.id), ["session", "weekly_all", "weekly_opus"])
            expectApprox(reading.windows[0].usedFraction, 0.38)
            expectEqual(reading.windows[0].resetsAt, date("2026-09-24T14:59:00Z"))
            expectEqual(reading.windows[2].resetsAt, date("2026-09-28T06:00:00Z"))
            expectEqual(reading.windows[1].label, "All models")
            expectEqual(reading.windows[0].fidelity, .official)
            expectEqual(reading.plan, "Max (20x)")
        },
        test("output without a session line is rejected") {
            expectThrows { _ = try ClaudeUsageCLI.parse("Total cost: $1.20", now: now) }
        },
        test("a reset near new year picks the nearest year") {
            let dec31 = date("2026-12-31T20:00:00Z")
            expectEqual(ClaudeUsageCLI.resetDate(from: "Jan 2 at 1am (UTC)", now: dec31), date("2027-01-02T01:00:00Z"))
        },
        test("the CLI is asked in safe, print-only mode") {
            let args = ClaudeUsageCLI.arguments
            expect(args.contains("--print") && args.contains("--safe-mode") && args.contains("--no-session-persistence"))
            expectEqual(args.last, "/usage")
        },
    ])
}
