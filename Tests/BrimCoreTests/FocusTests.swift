import Foundation
@testable import BrimCore

enum FocusTests {
    static let now = date("2026-09-26T10:00:00Z")

    static func session(_ pid: Int32?, _ name: String, provider: String = "claudeCode", state: SessionState = .busy,
                        ago: TimeInterval = 60) -> AgentSession {
        AgentSession(id: "\(provider).\(name)", providerID: provider, name: name, detail: "Terminal · \(name)",
                     state: state, since: now.addingTimeInterval(-ago), processID: pid)
    }

    static let suite = TestSuite("Focusing sessions", [
        test("a row goes to its own session, by its own process id, or nowhere") {
            let a = session(4101, "brim"), b = session(4102, "website", ago: 5)
            let running: Set<Int32> = [4101, 4102]
            expectEqual(FocusRoute.forRow(a, isRunning: running.contains), .session(a))
            expectEqual(FocusRoute.forRow(b, isRunning: running.contains), .session(b))
            // Never swapped for another session, however recent.
            expectEqual(FocusRoute.forRow(session(nil, "no-pid", ago: 1), isRunning: running.contains), .none)
            expectEqual(FocusRoute.forRow(session(4199, "gone", ago: 1), isRunning: running.contains), .none)
        },
        test("a ring goes to its waiting session first") {
            let waiting = session(4103, "asks", state: .waiting, ago: 300)
            let busy = session(4101, "brim", ago: 5)
            let route = FocusRoute.forRing([busy, waiting], app: .claude, isRunning: { _ in true })
            expectEqual(route, .session(waiting))
            // The one the first click acknowledged, when it still runs.
            let older = session(4104, "older-ask", state: .waiting, ago: 900)
            expectEqual(FocusRoute.forRing([busy, waiting, older], preferring: older, app: nil, isRunning: { _ in true }),
                        .session(older))
        },
        test("otherwise the most recently active session whose process still runs") {
            let newest = session(4101, "newest", ago: 5), older = session(4102, "older", ago: 50)
            let idle = session(4105, "idle", state: .idle, ago: 1)
            expectEqual(FocusRoute.forRing([idle, older, newest], app: nil, isRunning: { _ in true }), .session(newest))
            // A waiting session whose process has gone is skipped, not guessed at.
            let deadAsk = session(4103, "dead-ask", state: .waiting, ago: 1)
            expectEqual(FocusRoute.forRing([deadAsk, older, newest], app: nil, isRunning: { $0 != 4103 && $0 != 4101 }),
                        .session(older))
        },
        test("with no running process, the provider's own app; with none, nothing") {
            let gone = [session(4101, "brim"), session(nil, "never-had-one")]
            expectEqual(FocusRoute.forRing(gone, app: .claude, isRunning: { _ in false }), .app(.claude))
            expectEqual(FocusRoute.forRing([], app: .cursor, isRunning: { _ in true }), .app(.cursor))
            expectEqual(FocusRoute.forRing(gone, app: nil, isRunning: { _ in false }), .none)
        },
        test("only apps whose identity is certain; only Cursor is opened when not running") {
            expectEqual(ProviderApp.of(kind: .claudeCode, name: "Claude Code"), .claude)
            expectEqual(ProviderApp.of(kind: .codex, name: "Codex"), .codex)
            expectEqual(ProviderApp.of(kind: .manual, name: " Cursor "), .cursor)
            expectEqual(ProviderApp.of(kind: .demo, name: "Cursor"), .cursor)
            expectNil(ProviderApp.of(kind: .manual, name: "Team API budget"))
            expectNil(ProviderApp.of(kind: .ollama, name: "Ollama"))
            expect(ProviderApp.cursor.opens && !ProviderApp.claude.opens && !ProviderApp.codex.opens)
        },
        test("acknowledging one session's row quiets that session only") {
            var attention = WaitingAttention()
            attention.observe([:])
            let one = session(4101, "one", state: .waiting, ago: 10)
            let two = session(4102, "two", state: .waiting, ago: 20)
            let codex = session(5101, "api", provider: "codex", state: .waiting, ago: 30)
            attention.observe(["claudeCode": ActivitySummary(sessions: [one, two]), "codex": ActivitySummary(sessions: [codex])])
            attention.acknowledge(sessionID: one.id)
            expect(attention.isAsking("claudeCode"), "the other Claude session still waits")
            attention.acknowledge(sessionID: two.id)
            expect(!attention.isAsking("claudeCode"))
            expect(attention.isAsking("codex"))
        },
        test("Codex sessions carry the process that holds their rollout file open") {
            let finder = CodexProcessFinder(
                processIDs: { [10, 11, 12, 13] },
                name: { [10: "codex", 11: "Codex Helper (Renderer)", 12: "codex-aarch64-apple-darwin", 13: "zsh"][$0] },
                openFiles: { pid in
                    switch pid {
                    case 10: return ["/Users/me/.codex/sessions/2026/09/26/rollout-A.jsonl", "/dev/ttys001"]
                    case 11: return ["/Users/me/.codex/sessions/2026/09/26/rollout-B.jsonl"]
                    case 12: return ["/Users/me/.codex/sessions/2026/09/26/rollout-C.jsonl", "/tmp/rollout-C.jsonl.lock"]
                    default: return ["/Users/me/.codex/sessions/2026/09/26/rollout-D.jsonl"]
                    }
                })
            expectEqual(finder.owners(), ["rollout-A": 10, "rollout-C": 12])

            typealias Trace = CodexRolloutScanner.SessionTrace
            let traces: [String: Trace] = [
                "rollout-A": Trace(cwd: "/x/api", originator: nil, lastActivity: ("task_started", now), modified: now),
                "rollout-E": Trace(cwd: "/x/web", originator: nil, lastActivity: ("task_started", now), modified: now),
            ]
            let sessions = Dictionary(uniqueKeysWithValues: CodexProvider.sessions(from: traces, providerID: "codex", now: now,
                                                                                   owners: finder.owners())
                .map { ($0.name, $0) })
            expectEqual(sessions["api"]?.processID, 10)
            expectNil(sessions["web"]?.processID)
        },
        test("the kernel's list of open files is read by name only, and finds a file this process holds") {
            try await withTemporaryDirectory { root in
                let file = root.appendingPathComponent("rollout-probe.jsonl")
                try Data("{}\n".utf8).write(to: file)
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                let pid = getpid()
                expect(CodexProcessFinder.openFilePaths(pid).contains { $0.hasSuffix("/rollout-probe.jsonl") },
                       "the open file was not listed")
                expectEqual(CodexProcessFinder.processName(pid), ProcessInfo.processInfo.processName)
                expect(CodexProcessFinder.allProcessIDs().contains(pid))
                // Not a Codex process, so the finder passes it by.
                expectNil(CodexProcessFinder.system.owners()["rollout-probe"])
            }
        },
    ])
}
