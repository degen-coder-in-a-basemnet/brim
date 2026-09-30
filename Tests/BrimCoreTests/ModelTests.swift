import Foundation
@testable import BrimCore

enum ModelTests {
    static let now = date("2026-09-24T12:00:00Z")

    static func window(_ id: String, _ fraction: Double?, resets: TimeInterval? = nil) -> LimitWindow {
        LimitWindow(id: id, label: id, usedFraction: fraction, resetsAt: resets.map { now.addingTimeInterval($0) })
    }

    static func snapshot(_ windows: [LimitWindow], preferred: String? = nil, cellLabel: String? = nil) -> ProviderSnapshot {
        ProviderSnapshot(id: "p", kind: .manual, displayName: "P", glyph: .monogram("P"), fidelity: .manual,
                         windows: windows, capturedAt: now, cellLabel: cellLabel, preferredHeadlineID: preferred)
    }

    static let suite = TestSuite("Model", [
        test("fidelity qualifier marks only derived figures") {
            expectEqual(Fidelity.derived.qualifier, "≈")
            for fidelity in [Fidelity.official, .manual, .local, .unsupported] {
                expectEqual(fidelity.qualifier, "")
            }
        },
        test("percent rounds half up and never goes negative") {
            expectEqual(Percent.value(for: 0.725), 73)
            expectEqual(Percent.value(for: 0.994), 99)
            expectEqual(Percent.value(for: 0.995), 100)
            expectEqual(Percent.value(for: -0.2), 0)
            expectEqual(Percent.value(for: .nan), 0)
            expectEqual(Percent.text(for: 0.21), "21%")
        },
        test("headline is the most constrained window") {
            let s = snapshot([window("session", 0.2), window("week", 0.91), window("count", nil)])
            expectEqual(s.headline?.id, "week")
            expectApprox(s.usedFraction, 0.91)
            expectEqual(s.headlineText, "91%")
        },
        test("preferred headline wins when it has a reading") {
            expectEqual(snapshot([window("a", 0.2), window("b", 0.9)], preferred: "a").headline?.id, "a")
            expectEqual(snapshot([window("a", nil), window("b", 0.9)], preferred: "a").headline?.id, "b")
        },
        test("no reading shows a dash, not zero") {
            let s = snapshot([window("tokens", nil)])
            expect(!s.hasReading)
            expectEqual(s.headlineText, "—")
            expectEqual(snapshot([], cellLabel: "Idle").headlineText, "Idle")
        },
        test("a spent window blocks until it resets") {
            let spent = window("session", 1.0, resets: 600)
            expect(spent.isExhausted(now: now))
            expect(!spent.isExhausted(now: now.addingTimeInterval(601)))
            expect(!window("x", 0.99, resets: 600).isExhausted(now: now))
            expect(snapshot([spent]).isBlocked(now: now))
        },
        test("count rows have a value and nothing to be a share of") {
            expect(LimitWindow(id: "r", label: "Requests", detail: "12").isCountRow)
            expect(!LimitWindow(id: "r", label: "Requests", usedFraction: 0.1, detail: "12").isCountRow)
        },
        test("bands follow the design frame's thresholds") {
            expectEqual(UsageBand.band(for: 0.21), .ample)
            expectEqual(UsageBand.band(for: 0.49), .ample)
            expectEqual(UsageBand.band(for: 0.52), .watch)
            expectEqual(UsageBand.band(for: 0.73), .critical)
            expectEqual(UsageBand.band(for: 0.99), .critical)
            expectEqual(UsageBand.band(for: 1.0), .exhausted)
        },
        test("activity shows the most urgent session") {
            let base = AgentSession(id: "1", providerID: "p", name: "a", detail: "", state: .idle, since: now)
            var busy = base; busy.id = "2"; busy.state = .busy
            var waiting = base; waiting.id = "3"; waiting.state = .waiting
            expectEqual(ActivitySummary(sessions: [base, busy]).state, .busy)
            expectEqual(ActivitySummary(sessions: [base, busy, waiting]).state, .waiting)
            expectEqual(ActivitySummary(sessions: []).state, .idle)
            expectEqual(ActivitySummary(sessions: [base, busy, waiting]).ordered.map(\.id), ["3", "2", "1"])
        },
        test("stale marking keeps problem states") {
            let ok = snapshot([window("a", 0.5)])
            expect(ok.markedStale(since: now).status.isStale)
            var broken = ok
            broken.status = .unavailable("gone")
            expectEqual(broken.markedStale(since: now).status, .unavailable("gone"))
        },
    ])
}

enum CopyTests {
    static let now = date("2026-09-24T12:00:00Z")   // a Thursday
    static let locale = Locale(identifier: "en_US_POSIX")

    /// ICU puts a narrow no-break space before AM/PM; compare with plain spaces.
    static func text(_ seconds: TimeInterval, _ format: ResetTimeFormat = .automatic) -> String {
        ResetCopy.text(for: now.addingTimeInterval(seconds), now: now, calendar: utc, format: format, locale: locale)
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }

    static let suite = TestSuite("Copy", [
        test("under an hour reads in minutes, rounded") {
            expectEqual(text(51 * 60), "Resets in 51 min")
            expectEqual(text(50 * 60 + 40), "Resets in 51 min")
            expectEqual(text(20), "Resets in 1 min")
        },
        test("an hour or more reads as a weekday and time") {
            expectEqual(text(59 * 60 + 50), "Resets Thu 12:59 PM")
            expectEqual(text(12 * 3600), "Resets Fri 12:00 AM")
        },
        test("a week or more reads as a date") {
            expectEqual(text(10 * 86_400), "Resets Oct 4")
        },
        test("past resets say resetting") {
            expectEqual(text(-5), "Resetting…")
            expectEqual(text(0), "Resetting…")
        },
        test("time remaining format counts down") {
            expectEqual(text(51 * 60, .remaining), "Resets in 51 min")
            expectEqual(text(3 * 3600 + 20 * 60, .remaining), "Resets in 3h 20m")
            expectEqual(text(3 * 86_400 + 3 * 3600, .remaining), "Resets in 3 Days 3h")
            expectEqual(text(86_400 + 3600, .remaining), "Resets in 1 Day 1h")
        },
        test("menu bar countdown truncates and pads") {
            expectEqual(ResetCopy.countdown(to: now.addingTimeInterval(30), now: now), "<1m")
            expectEqual(ResetCopy.countdown(to: now.addingTimeInterval(47 * 60 + 59), now: now), "47m")
            expectEqual(ResetCopy.countdown(to: now.addingTimeInterval(2 * 3600 + 5 * 60), now: now), "2h 05m")
            expectEqual(ResetCopy.countdown(to: now.addingTimeInterval(3 * 86_400), now: now), "3d 0h")
            expectNil(ResetCopy.countdown(to: now.addingTimeInterval(-1), now: now))
        },
        test("elapsed copy") {
            expectEqual(ElapsedCopy.ago(since: now.addingTimeInterval(-20), now: now), "just now")
            expectEqual(ElapsedCopy.ago(since: now.addingTimeInterval(-4 * 60), now: now), "4 min ago")
            expectEqual(ElapsedCopy.ago(since: now.addingTimeInterval(-3 * 3600), now: now), "3h ago")
            expectEqual(ElapsedCopy.ago(since: now.addingTimeInterval(-3 * 86_400), now: now), "3d ago")
            expectEqual(ElapsedCopy.duration(since: now.addingTimeInterval(-42), now: now), "42s")
            expectEqual(ElapsedCopy.duration(since: now.addingTimeInterval(-3 * 3600 - 120), now: now), "3h 2m")
        },
        test("compact counts") {
            expectEqual(CountFormat.compact(950), "950")
            expectEqual(CountFormat.compact(12_400), "12.4K")
            expectEqual(CountFormat.compact(4_100_000), "4.1M")
            expectEqual(CountFormat.compact(4_000_000), "4M")
            expectEqual(CountFormat.compact(250_000_000), "250M")
            expectEqual(CountFormat.compact(2_300_000_000), "2.3B")
        },
    ])
}

enum AlertTests {
    static func reading(_ fraction: Double?, status: ProviderStatus = .ok, id: String = "claude") -> ProviderSnapshot {
        ProviderSnapshot(id: id, kind: .claudeCode, displayName: "Claude", glyph: .asterisk, fidelity: .official,
                         windows: [LimitWindow(id: "session", label: "Current session", usedFraction: fraction,
                                               resetsAt: date("2026-09-24T15:00:00Z"))],
                         capturedAt: Date(), status: status)
    }

    static let suite = TestSuite("Threshold alerts", [
        test("the first reading only records") {
            let tracker = ThresholdTracker()
            expect(tracker.observe([reading(0.95)]).isEmpty)
            expect(tracker.observe([reading(0.97)]).isEmpty)
        },
        test("crossing 80 alerts once") {
            let tracker = ThresholdTracker()
            _ = tracker.observe([reading(0.5)])
            let alerts = tracker.observe([reading(0.82)])
            expectEqual(alerts.map(\.threshold), [80])
            expectEqual(alerts.first?.usedPercent, 82)
            expect(tracker.observe([reading(0.9)]).isEmpty)
        },
        test("reaching 100 alerts again") {
            let tracker = ThresholdTracker()
            _ = tracker.observe([reading(0.5)])
            _ = tracker.observe([reading(0.85)])
            let alerts = tracker.observe([reading(1.0)])
            expectEqual(alerts.map(\.threshold), [100])
            expect(alerts[0].title.contains("limit reached"))
        },
        test("a jump straight to 100 alerts for both") {
            let tracker = ThresholdTracker()
            _ = tracker.observe([reading(0.1)])
            expectEqual(tracker.observe([reading(1.0)]).map(\.threshold), [80, 100])
        },
        test("falling back below 80 re-arms") {
            let tracker = ThresholdTracker()
            _ = tracker.observe([reading(0.5)])
            _ = tracker.observe([reading(0.85)])
            _ = tracker.observe([reading(0.05)])
            expectEqual(tracker.observe([reading(0.81)]).map(\.threshold), [80])
        },
        test("muted providers stay quiet but keep their memory") {
            let tracker = ThresholdTracker()
            _ = tracker.observe([reading(0.5)])
            expect(tracker.observe([reading(0.85)], isMuted: { _ in true }).isEmpty)
            expect(tracker.observe([reading(0.86)]).isEmpty)
        },
        test("stale readings are not a baseline") {
            let tracker = ThresholdTracker()
            _ = tracker.observe([reading(0.95, status: .stale(since: Date()))])
            expect(tracker.observe([reading(0.96)]).isEmpty, "first live reading only records")
            expectEqual(tracker.observe([reading(1.0)]).map(\.threshold), [100])
        },
        test("derived alerts carry the estimate marker") {
            let tracker = ThresholdTracker()
            var low = reading(0.5)
            low.windows[0].fidelity = .derived
            var high = reading(0.84)
            high.windows[0].fidelity = .derived
            _ = tracker.observe([low])
            let alert = tracker.observe([high]).first
            expectEqual(alert?.title, "Claude is at ≈84%")
        },
    ])
}

enum TransitionTests {
    static let now = Date()

    static func session(_ id: String, _ state: SessionState, waitingFor: String? = nil) -> AgentSession {
        AgentSession(id: id, providerID: "claude", name: "brim", detail: "Terminal · brim", state: state,
                     since: now, processID: 42, waitingFor: waitingFor)
    }

    static let suite = TestSuite("Session transitions", [
        test("first sighting is silent") {
            let detector = SessionTransitionDetector()
            expect(detector.observe([session("a", .busy)], providerName: { _ in "Claude" }).isEmpty)
        },
        test("busy to finished announces finished") {
            let detector = SessionTransitionDetector()
            _ = detector.observe([session("a", .busy)], providerName: { _ in "Claude" })
            let events = detector.observe([session("a", .finished)], providerName: { _ in "Claude" })
            expectEqual(events.map(\.kind), [.finished])
            expectEqual(events.first?.session.processID, 42)
            expectEqual(events.first?.title, "Claude finished")
        },
        test("busy to idle also counts as finishing") {
            let detector = SessionTransitionDetector()
            _ = detector.observe([session("a", .busy)], providerName: { _ in "Claude" })
            expectEqual(detector.observe([session("a", .idle)], providerName: { _ in "Claude" }).map(\.kind), [.finished])
        },
        test("any move into waiting announces waiting") {
            let detector = SessionTransitionDetector()
            _ = detector.observe([session("a", .busy)], providerName: { _ in "Claude" })
            let events = detector.observe([session("a", .waiting, waitingFor: "Permission")], providerName: { _ in "Claude" })
            expectEqual(events.map(\.kind), [.waiting])
            expectEqual(events.first?.body, "brim: Permission")
        },
        test("vanishing and idle churn are silent") {
            let detector = SessionTransitionDetector()
            _ = detector.observe([session("a", .busy)], providerName: { _ in "C" })
            expect(detector.observe([], providerName: { _ in "C" }).isEmpty)
            _ = detector.observe([session("b", .idle)], providerName: { _ in "C" })
            expect(detector.observe([session("b", .stale)], providerName: { _ in "C" }).isEmpty)
            expect(detector.observe([session("b", .idle)], providerName: { _ in "C" }).isEmpty)
        },
        test("waiting to busy is not an event") {
            let detector = SessionTransitionDetector()
            _ = detector.observe([session("a", .waiting)], providerName: { _ in "C" })
            expect(detector.observe([session("a", .busy)], providerName: { _ in "C" }).isEmpty)
        },
    ])
}

enum OrderingTests {
    static let suite = TestSuite("Provider ordering", [
        test("applies the saved order and appends the rest") {
            expectEqual(ProviderOrdering.apply(order: ["codex", "claudeCode"], to: ["claudeCode", "ollama", "codex"]),
                        ["codex", "claudeCode", "ollama"])
        },
        test("unknown ids in the order are ignored") {
            expectEqual(ProviderOrdering.apply(order: ["gone", "b"], to: ["a", "b"]), ["b", "a"])
        },
        test("a provider switched back on joins the end") {
            expectEqual(ProviderOrdering.enabling("a", in: ["a", "b", "c"]), ["b", "c", "a"])
            expectEqual(ProviderOrdering.enabling("d", in: ["a", "b"]), ["a", "b", "d"])
        },
        test("moves behave like a list reorder") {
            let order = ["a", "b", "c", "d"]
            expectEqual(ProviderOrdering.move(order, fromOffsets: [0], toOffset: 3), ["b", "c", "a", "d"])
            expectEqual(ProviderOrdering.move(order, fromOffsets: [3], toOffset: 0), ["d", "a", "b", "c"])
            expectEqual(ProviderOrdering.move(order, fromOffsets: [1, 2], toOffset: 4), ["a", "d", "b", "c"])
        },
        test("duplicates collapse to the first") {
            expectEqual(ProviderOrdering.deduplicated(["a", "b", "a"]), ["a", "b"])
        },
    ])
}

enum StalenessTests {
    static let now = date("2026-09-24T12:00:00Z")

    static let suite = TestSuite("Staleness", [
        test("polled readings dim after three missed polls, never under ten minutes") {
            expectEqual(Staleness.maxAge(for: .claudeCode, refreshInterval: 60), 600)
            expectEqual(Staleness.maxAge(for: .claudeCode, refreshInterval: 600), 1800)
            expectEqual(Staleness.maxAge(for: .codex, refreshInterval: 60), 1800)
            expect(!Staleness.maxAge(for: .manual, refreshInterval: 60).isFinite)
        },
        test("old figures are marked stale from when they were true") {
            let captured = now.addingTimeInterval(-3600)
            let s = ProviderSnapshot(id: "codex", kind: .codex, displayName: "Codex", glyph: .prompt,
                                     fidelity: .official, windows: [LimitWindow(id: "p", label: "p", usedFraction: 0.3)],
                                     capturedAt: captured)
            let evaluated = Staleness.evaluate(s, now: now, maxAge: 1800)
            expectEqual(evaluated.status, .stale(since: captured))
            expectEqual(Staleness.evaluate(s, now: now, maxAge: 7200).status, .ok)
        },
        test("problem states are left as they are") {
            let s = ProviderSnapshot(id: "o", kind: .ollama, displayName: "O", glyph: .monogram("O"), fidelity: .local,
                                     capturedAt: now.addingTimeInterval(-99_999), status: .unavailable("off"))
            expectEqual(Staleness.evaluate(s, now: now, maxAge: 60).status, .unavailable("off"))
        },
    ])
}
