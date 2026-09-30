import Foundation
@testable import BrimCore

enum AttentionTests {
    static let t0 = date("2026-09-25T10:00:00Z")

    static func session(_ id: String, _ state: SessionState, provider: String = "claudeCode",
                        since: Date = t0, pid: Int32? = 4242) -> AgentSession {
        AgentSession(id: id, providerID: provider, name: "brim", detail: "Terminal · brim", state: state,
                     since: since, processID: pid)
    }

    static func activity(_ sessions: AgentSession...) -> [String: ActivitySummary] {
        Dictionary(grouping: sessions, by: \.providerID).mapValues { ActivitySummary(sessions: $0) }
    }

    /// A tracker that has already had its first look, at a busy session.
    static func watching(_ sessions: AgentSession...) -> WaitingAttention {
        var attention = WaitingAttention()
        attention.observe(Dictionary(grouping: sessions, by: \.providerID).mapValues { ActivitySummary(sessions: $0) })
        return attention
    }

    static let suite = TestSuite("Waiting attention", [
        test("busy → waiting starts asking") {
            var attention = watching(session("a", .busy))
            let started = attention.observe(activity(session("a", .waiting, since: t0 + 60)))
            expectEqual(started, ["claudeCode"])
            expectEqual(attention.providers, ["claudeCode"])
            expect(attention.isAsking("claudeCode"))
        },
        test("it keeps asking for as long as the session waits: there is no timer") {
            var attention = watching(session("a", .busy))
            attention.observe(activity(session("a", .waiting, since: t0 + 60)))
            // Far past any peek duration, the same stretch of waiting.
            for _ in 0..<5 {
                let started = attention.observe(activity(session("a", .waiting, since: t0 + 60)))
                expectEqual(started, [], "announced the same wait twice")
            }
            expectEqual(attention.providers, ["claudeCode"])
        },
        test("an answer ends it: waiting → busy, finished or idle") {
            for next: SessionState in [.busy, .finished, .idle] {
                var attention = watching(session("a", .busy))
                attention.observe(activity(session("a", .waiting, since: t0 + 60)))
                attention.observe(activity(session("a", next, since: t0 + 90)))
                expectEqual(attention.providers, [], "still asking after \(next)")
            }
        },
        test("a session that disappears stops asking") {
            var attention = watching(session("a", .busy))
            attention.observe(activity(session("a", .waiting, since: t0 + 60)))
            attention.observe([:])
            expectEqual(attention.providers, [])
        },
        test("whatever is already waiting at the first look is not news") {
            var attention = WaitingAttention()
            let started = attention.observe(activity(session("a", .waiting)))
            expectEqual(started, [])
            expectEqual(attention.providers, [])
        },
        test("acknowledging quiets that provider only") {
            var attention = watching(session("a", .busy), session("b", .busy, provider: "codex"))
            attention.observe(activity(session("a", .waiting, since: t0 + 60), session("b", .waiting, provider: "codex", since: t0 + 61)))
            expectEqual(attention.providers, ["claudeCode", "codex"])
            attention.acknowledge(providerID: "claudeCode")
            expectEqual(attention.providers, ["codex"])
            // Still waiting, but seen: the next poll doesn't bring it back.
            attention.observe(activity(session("a", .waiting, since: t0 + 60), session("b", .waiting, provider: "codex", since: t0 + 61)))
            expectEqual(attention.providers, ["codex"])
        },
        test("a new waiting episode asks again after an acknowledgement") {
            var attention = watching(session("a", .busy))
            attention.observe(activity(session("a", .waiting, since: t0 + 60)))
            attention.acknowledge(providerID: "claudeCode")
            attention.observe(activity(session("a", .busy, since: t0 + 90)))
            let again = attention.observe(activity(session("a", .waiting, since: t0 + 120)))
            expectEqual(again, ["claudeCode"])
            expectEqual(attention.providers, ["claudeCode"])
        },
        test("a fresh wait still asks when a poll missed the answer in between") {
            var attention = watching(session("a", .busy))
            attention.observe(activity(session("a", .waiting, since: t0 + 60)))
            attention.acknowledge(providerID: "claudeCode")
            let again = attention.observe(activity(session("a", .waiting, since: t0 + 300)))
            expectEqual(again, ["claudeCode"])
        },
        test("several waiting sessions on one provider") {
            var attention = watching(session("a", .busy), session("b", .busy))
            attention.observe(activity(session("a", .waiting, since: t0 + 60), session("b", .waiting, since: t0 + 70)))
            expectEqual(attention.providers, ["claudeCode"])
            attention.acknowledge(providerID: "claudeCode")
            expectEqual(attention.providers, [], "one click should cover every session it was showing")
            // A third starts waiting: that is new, and asks.
            attention.observe(activity(session("a", .waiting, since: t0 + 60), session("b", .waiting, since: t0 + 70),
                                       session("c", .waiting, since: t0 + 80)))
            expectEqual(attention.providers, ["claudeCode"])
            // Answering an acknowledged one leaves the new one asking.
            attention.observe(activity(session("a", .busy, since: t0 + 90), session("b", .waiting, since: t0 + 70),
                                       session("c", .waiting, since: t0 + 80)))
            expectEqual(attention.providers, ["claudeCode"])
        },
        test("several providers can ask at once, and clear independently") {
            var attention = watching(session("a", .busy), session("b", .busy, provider: "codex"), session("c", .busy, provider: "demo.claude"))
            attention.observe(activity(session("a", .waiting, since: t0 + 60), session("b", .waiting, provider: "codex", since: t0 + 60),
                                       session("c", .busy, provider: "demo.claude")))
            expectEqual(attention.providers, ["claudeCode", "codex"])
            attention.observe(activity(session("a", .waiting, since: t0 + 60), session("b", .busy, provider: "codex", since: t0 + 90),
                                       session("c", .busy, provider: "demo.claude")))
            expectEqual(attention.providers, ["claudeCode"])
        },
        test("a double-click raises the newest waiting session with a process") {
            let sessions = activity(session("old", .waiting, since: t0, pid: 11), session("new", .waiting, since: t0 + 60, pid: nil),
                                    session("busy", .busy, since: t0 + 90, pid: 33))
            expectEqual(WaitingAttention.focusTarget(providerID: "claudeCode", in: sessions)?.id, "old")
            let noProcess = activity(session("only", .waiting, pid: nil))
            let target = WaitingAttention.focusTarget(providerID: "claudeCode", in: noProcess)
            expectEqual(target?.id, "only")
            expectNil(target?.processID)
            expectNil(WaitingAttention.focusTarget(providerID: "codex", in: noProcess))
        },
    ])
}
