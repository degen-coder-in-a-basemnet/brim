import Foundation
@testable import BrimCore

/// A ~/.claude.json laid out like the real one: account details, a key, prompt
/// history, and decoys of the usage entry nested deeper and quoted inside a
/// string. Only the top-level entry may be read; the canaries must never
/// surface anywhere.
enum ClaudeConfigFixtures {
    static let secret = "sk-ant-api03-CANARY-SECRET"
    static let prompt = "CANARY-PROMPT-HISTORY"

    static func config(fetchedAt: Date, session: (Int, String)?, weekly: (Int, String)?) -> String {
        func window(_ value: (Int, String)?) -> String {
            guard let value else { return "null" }
            return #"{"utilization":\#(value.0),"resets_at":"\#(value.1)","limit_dollars":null,"used_dollars":null,"locked_reason":null}"#
        }
        let millis = Int(fetchedAt.timeIntervalSince1970 * 1000)
        return """
        {
          "numStartups": 412,
          "primaryApiKey": "\(secret)",
          "oauthAccount": {"emailAddress": "someone@example.com", "organizationName": "Example"},
          "projects": {
            "/Users/me/brim": {
              "history": [{"display": "\(prompt) \\"cachedUsageUtilization\\": {\\"fetchedAtMs\\": 1}", "pastedContents": {}}],
              "cachedUsageUtilization": {"fetchedAtMs": 1, "utilization": {"five_hour": {"utilization": 99, "resets_at": null}}}
            }
          },
          "cachedUsageUtilization": {
            "fetchedAtMs": \(millis),
            "accountUuid": "00000000-0000-0000-0000-000000000000",
            "utilization": {
              "five_hour": \(window(session)),
              "seven_day": \(window(weekly)),
              "seven_day_opus": null,
              "seven_day_sonnet": null,
              "extra_usage": {"is_enabled": false, "monthly_limit": null},
              "limits": [{"kind": "session", "percent": 51, "resets_at": "x"}]
            }
          },
          "tipsHistory": {"x": 1}
        }
        """
    }
}

enum ClaudeOfficialTests {
    typealias F = ClaudeFixtures
    typealias C = ClaudeConfigFixtures
    static let now = date("2026-09-24T18:00:00Z")
    static let fetched = date("2026-09-24T17:51:11Z")
    static let coverage = date("2026-09-17T00:00:00Z")

    static func reading(session: Double = 0.51, weekly: Double = 0.20, at: Date = fetched) -> OfficialReading {
        OfficialReading(at: at, windows: [
            "session": OfficialWindow(fraction: session, resetsAt: date("2026-09-24T22:19:59Z")),
            "weekly_all": OfficialWindow(fraction: weekly, resetsAt: date("2026-10-01T02:59:59Z")),
        ], plan: nil, origin: .cache)
    }

    static func events(_ items: [(String, Int)]) -> [UsageEvent] {
        F.ledger(items.enumerated().map {
            F.assistant(id: "m\($0.offset)", request: "r\($0.offset)", at: $0.element.0, input: $0.element.1, output: 0)
        }).sortedUsage
    }

    static func budgets(session: Double) -> ClaudeUsageEstimator.Budgets {
        var budgets = ClaudeUsageEstimator.Budgets()
        budgets.session = session
        return budgets
    }

    static let suite = TestSuite("Claude official figures", [
        test("only the top-level entry is cut out of ~/.claude.json") {
            let text = C.config(fetchedAt: fetched, session: (51, "2026-09-24T22:19:59.918271+00:00"), weekly: nil)
            let slice = JSONSlice.topLevelObject(forKey: ClaudeUsageCache.key, in: Data(text.utf8))
            let cut = slice.map { String(decoding: $0, as: UTF8.self) } ?? ""
            expect(cut.hasPrefix("{") && cut.contains("\(Int(fetched.timeIntervalSince1970 * 1000))"), "took a decoy")
            expect(!cut.contains(C.secret) && !cut.contains(C.prompt) && !cut.contains("example.com"),
                   "the cut reaches outside the entry")
        },
        test("reads Anthropic's percentages and exact resets") {
            let text = C.config(fetchedAt: fetched, session: (51, "2026-09-24T22:19:59.918271+00:00"),
                                weekly: (20, "2026-10-01T02:59:59.918293+00:00"))
            let reading = ClaudeUsageCache.reading(from: Data(text.utf8))
            expectEqual(reading?.at, fetched)
            expectApprox(reading?.windows["session"]?.fraction, 0.51)
            expectApprox(reading?.windows["weekly_all"]?.fraction, 0.20)
            expectApprox(reading?.windows["session"]?.resetsAt?.timeIntervalSince1970,
                         date("2026-09-24T22:19:59Z").timeIntervalSince1970 + 0.918, tolerance: 0.001)
            expectNil(reading?.windows["weekly_opus"])
            expectEqual(reading?.origin, .cache)
        },
        test("a file without the entry, or with nothing usable in it, gives no reading") {
            expectNil(ClaudeUsageCache.reading(from: Data(#"{"numStartups": 3}"#.utf8)))
            expectNil(ClaudeUsageCache.reading(from: Data(C.config(fetchedAt: fetched, session: nil, weekly: nil).utf8)))
            expectNil(ClaudeUsageCache.reading(from: Data("not json {".utf8)))
        },
        test("with nothing logged since, Anthropic's figure stands as reported") {
            let windows = ClaudeUsageEstimator.windows(events: events([("2026-09-24T17:40:00.000Z", 5000)]), limits: [],
                                                       official: reading(), now: now, budgets: .init())
            let session = windows.first { $0.id == "session" }
            expectApprox(session?.usedFraction, 0.51)
            expectEqual(session?.fidelity, .official)
            expectEqual(session?.resetsAt, date("2026-09-24T22:19:59Z"))
            expect(session?.note?.contains("Reported by Anthropic") == true, session?.note ?? "no note")
            expectApprox(windows.first { $0.id == "weekly_all" }?.usedFraction, 0.20)
        },
        test("responses logged since move it on, marked as an estimate") {
            let windows = ClaudeUsageEstimator.windows(
                events: events([("2026-09-24T17:40:00.000Z", 5000), ("2026-09-24T17:55:00.000Z", 10_000)]),
                limits: [], official: reading(), now: now, budgets: budgets(session: 100_000))
            let session = windows.first { $0.id == "session" }
            expectApprox(session?.usedFraction, 0.61)
            expectEqual(session?.fidelity, .derived)
            expect(session?.note?.contains("51%") == true, session?.note ?? "no note")
        },
        test("without a budget the reported figure stays, flagged as behind") {
            let windows = ClaudeUsageEstimator.windows(events: events([("2026-09-24T17:55:00.000Z", 10_000)]), limits: [],
                                                       official: reading(), now: now, budgets: .init())
            let session = windows.first { $0.id == "session" }
            expectApprox(session?.usedFraction, 0.51)
            expectEqual(session?.fidelity, .official)
            expect(session?.note?.contains("more used since") == true, session?.note ?? "no note")
        },
        test("an estimate on top of a figure never claims the limit is spent") {
            let windows = ClaudeUsageEstimator.windows(events: events([("2026-09-24T17:55:00.000Z", 10_000)]), limits: [],
                                                       official: reading(session: 0.9), now: now,
                                                       budgets: budgets(session: 1000))
            expectApprox(windows.first { $0.id == "session" }?.usedFraction, ClaudeUsageEstimator.derivedCeiling)
        },
        test("once the reported window has reset, the logs take over") {
            let windows = ClaudeUsageEstimator.windows(events: events([("2026-09-24T22:40:00.000Z", 20_000)]), limits: [],
                                                       official: reading(), now: date("2026-09-24T23:00:00Z"),
                                                       budgets: budgets(session: 100_000))
            let session = windows.first { $0.id == "session" }
            expectApprox(session?.usedFraction, 0.2)
            expectEqual(session?.fidelity, .derived)
            expectEqual(session?.resetsAt, date("2026-09-25T03:40:00Z"))
        },
        test("a rejection outranks an earlier reported figure") {
            let ledger = F.ledger([F.limit(at: "2026-09-24T17:58:00.000Z", resetsAt: date("2026-09-24T22:10:00Z"))])
            let windows = ClaudeUsageEstimator.windows(events: [], limits: ledger.limits, official: reading(),
                                                       now: now, budgets: .init())
            let session = windows.first { $0.id == "session" }
            expectEqual(session?.usedFraction, 1)
            expectEqual(session?.fidelity, .official)
        },
        test("a model's weekly figure shows when Anthropic reports one") {
            var official = reading()
            official.windows["weekly_opus"] = OfficialWindow(fraction: 0.4, resetsAt: date("2026-10-01T02:59:59Z"))
            let windows = ClaudeUsageEstimator.windows(events: [], limits: [], official: official, now: now,
                                                       budgets: .init())
            let opus = windows.first { $0.id == "weekly_opus" }
            expectEqual(opus?.label, "Opus")
            expectApprox(opus?.usedFraction, 0.4)
            expectEqual(opus?.fidelity, .official)
        },
        test("a reported percentage sizes the budget: what was spent, over the share it was") {
            let calibration = ClaudeUsageEstimator.calibration(
                events: events([("2026-09-24T17:30:00.000Z", 30_000), ("2026-09-24T17:50:00.000Z", 20_000),
                                ("2026-09-24T17:55:00.000Z", 99_999), ("2026-09-24T16:00:00.000Z", 77_777)]),
                limits: [], official: [reading(session: 0.5)], coverageStart: coverage)
            expectApprox(calibration.sessionBudget, 100_000)
            expectEqual(calibration.sessionMeasuredAt, fetched)
        },
        test("too small a percentage is not measured from") {
            let calibration = ClaudeUsageEstimator.calibration(
                events: events([("2026-09-24T17:30:00.000Z", 3000)]), limits: [],
                official: [reading(session: 0.03, weekly: 0.02)], coverageStart: coverage)
            expectNil(calibration.sessionBudget)
            expectNil(calibration.weeklyBudget)
        },
        test("the later of a limit hit and a reported figure wins") {
            let hit = F.ledger([
                F.assistant(id: "a", request: "1", at: "2026-09-24T12:00:00.000Z", input: 8000, output: 0),
                F.limit(at: "2026-09-24T14:23:53.000Z", resetsAt: date("2026-09-24T16:50:00Z")),
            ])
            let calibration = ClaudeUsageEstimator.calibration(
                events: hit.sortedUsage + events([("2026-09-24T17:30:00.000Z", 5000)]), limits: hit.limits,
                official: [reading(session: 0.5)], coverageStart: coverage)
            expectApprox(calibration.sessionBudget, 10_000)
            expectEqual(calibration.sessionMeasuredAt, fetched)
        },
        test("two readings of one window size the budget from the rise between them") {
            // Measured live: 51% then 78%, with near-identical logged use either
            // side of the first reading. The single-reading budget overshot.
            let first = reading(session: 0.51)
            let second = reading(session: 0.78, at: date("2026-09-24T18:05:39Z"))
            let calibration = ClaudeUsageEstimator.calibration(
                events: events([("2026-09-24T17:40:00.000Z", 51_000), ("2026-09-24T18:00:00.000Z", 54_000)]),
                limits: [], official: [second, first], coverageStart: coverage)
            expectApprox(calibration.sessionBudget, 200_000)
            expectEqual(calibration.sessionMeasuredAt, date("2026-09-24T18:05:39Z"))
        },
        test("the provider shows the cached figure, and nothing else from the file") {
            await withTemporaryDirectory { root in
                let environment = ProviderEnvironment(home: root, applicationSupport: root.appendingPathComponent("Support"))
                let now = Date()
                let iso = ISO8601DateFormatter()
                write(F.assistant(id: "a", request: "1", at: iso.string(from: now.addingTimeInterval(-600)),
                                  input: 1000, output: 0) + "\n",
                      to: environment.claudeDirectory.appendingPathComponent("projects/-Users-me-brim/s1.jsonl"))
                write(C.config(fetchedAt: now.addingTimeInterval(-300),
                               session: (51, iso.string(from: now.addingTimeInterval(3600))),
                               weekly: (20, iso.string(from: now.addingTimeInterval(3 * 86_400)))),
                      to: environment.claudeConfigFile)

                let provider = ClaudeCodeProvider(environment: environment, files: .standard(environment),
                                                  settings: ClaudeSettings(), showSessionTitles: false, calibration: nil)
                let snapshot = await provider.fetchSnapshot(now: now)
                let session = snapshot.windows.first { $0.id == "session" }
                expectApprox(session?.usedFraction, 0.51)
                expectEqual(session?.fidelity, .official)
                expectEqual(snapshot.fidelity, .official)
                expect(snapshot.source?.contains("Claude Code's cache") == true, snapshot.source ?? "no source")
                let dump = String(describing: snapshot)
                expect(!dump.contains(C.secret) && !dump.contains(C.prompt) && !dump.contains("example.com"),
                       "file contents reached the snapshot")

                var off = ClaudeSettings()
                off.readUsageCache = false
                await provider.update(settings: off, showSessionTitles: false)
                let without = await provider.fetchSnapshot(now: now)
                expectEqual(without.windows.first { $0.id == "session" }?.fidelity, .derived)
            }
        },
    ])
}
