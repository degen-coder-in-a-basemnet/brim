import AppKit
import SwiftUI
@testable import BrimCore
@testable import BrimUI

/// What a notch asked the app to do.
@MainActor
final class FocusRecord {
    var refreshed: [String] = []
    var usagePages: [String] = []
    var focused: [AgentSession] = []
    var openedApps: [ProviderApp] = []
    var acknowledgedRings: [String] = []
    var acknowledgedSessions: [String] = []
}

enum FocusUITests {
    static let now = date("2026-09-26T10:00:00Z")
    static let interval: TimeInterval = 0.05

    static func session(_ pid: Int32?, _ name: String, provider: String = "claudeCode", state: SessionState = .busy,
                        ago: TimeInterval = 60) -> AgentSession {
        AgentSession(id: "\(provider).\(name)", providerID: provider, name: name, detail: "Terminal · \(name)",
                     state: state, since: now.addingTimeInterval(-ago), processID: pid)
    }

    static func ring(_ id: String, _ kind: ProviderKind, _ name: String) -> ProviderSnapshot {
        ProviderSnapshot(id: id, kind: kind, displayName: name, glyph: kind.defaultGlyph, fidelity: .official,
                         windows: [LimitWindow(id: "five", label: "5-hour", usedFraction: 0.73, resetsAt: nil,
                                               duration: 5 * 3600, fidelity: .official)])
    }

    static let rings = [ring("claudeCode", .claudeCode, "Claude Code"), ring("codex", .codex, "Codex"),
                        ring("manual.cursor", .manual, "Cursor")]

    /// An open notch whose actions are recorded. `running` are the process ids
    /// that still run.
    @MainActor
    static func notch(_ sessions: [AgentSession], asking: Set<String> = [], running: Set<Int32>,
                      focusesSessions: Bool = true, record: FocusRecord) -> NotchController? {
        guard let screen = NSScreen.screens.first else { return nil }
        let controller = NotchController(screen: screen)
        controller.doubleClickInterval = { interval }
        let activity = Dictionary(grouping: sessions, by: \.providerID).mapValues { ActivitySummary(sessions: $0) }
        controller.model.snapshots = rings
        controller.model.activity = activity
        controller.model.waitingProviders = asking
        controller.model.isExpanded = true
        var actions = NotchActions()
        actions.refresh = { record.refreshed.append($0) }
        actions.openUsagePage = { record.usagePages.append($0) }
        actions.focusSession = { session in
            record.focused.append(session)
            return true
        }
        actions.openProviderApp = { app in
            record.openedApps.append(app)
            return true
        }
        actions.acknowledgeWaiting = { [weak controller] id in
            record.acknowledgedRings.append(id)
            controller?.model.waitingProviders.remove(id)
        }
        actions.acknowledgeSession = { record.acknowledgedSessions.append($0.id) }
        actions.waitingSession = { WaitingAttention.focusTarget(providerID: $0, in: activity) }
        actions.clickFocusesSession = { focusesSessions }
        actions.isProcessRunning = { running.contains($0) }
        controller.actions = actions
        return controller
    }

    /// Lets held single clicks run out their double-click interval.
    static func afterTheInterval() async throws {
        try await Task.sleep(nanoseconds: UInt64(interval * 3 * 1e9))
    }

    static let suite = TestSuite("Focusing from the notch", [
        test("two Claude sessions: each row focuses its own session, with its own process id") { @MainActor in
            let record = FocusRecord()
            let brim = session(4101, "brim", ago: 5), website = session(4102, "website", ago: 50)
            guard let notch = notch([brim, website], running: [4101, 4102], record: record) else {
                return expect(false, "needs a display")
            }
            let shown = SessionList.shown(ActivitySummary(sessions: [website, brim]))
            expectEqual(shown.map(\.processID), [4101, 4102])
            for row in shown {
                notch.model.isExpanded = true
                SessionRow(session: row, now: now, onFocus: notch.model.onFocusSession).focus()
                expectEqual(record.focused.last, row)
                expectEqual(record.focused.last?.processID, row.processID)
                expect(!notch.model.isExpanded, "the notch folds once the session's app is forward")
            }
            expectEqual(record.focused.map(\.id), [brim.id, website.id])
            try await afterTheInterval()
            expectEqual(record.refreshed, [], "a row click never refreshes")
            expectEqual(record.acknowledgedRings, [])
        },
        test("a row without a running process is never swapped for another session") { @MainActor in
            let record = FocusRecord()
            let live = session(4101, "live", ago: 1)
            let gone = session(4199, "gone", ago: 50), unknown = session(nil, "unknown", ago: 60)
            guard let notch = notch([live, gone, unknown], running: [4101], record: record) else {
                return expect(false, "needs a display")
            }
            notch.focusRow(gone)
            notch.focusRow(unknown)
            expectEqual(record.focused, [])
            expect(notch.model.isExpanded, "nothing came forward, so the notch stays open")
        },
        test("a waiting row acknowledges that session only, then focuses it") { @MainActor in
            let record = FocusRecord()
            let asks = session(4103, "asks", state: .waiting, ago: 30), other = session(4104, "other", state: .waiting)
            guard let notch = notch([asks, other], asking: ["claudeCode"], running: [4103, 4104], record: record) else {
                return expect(false, "needs a display")
            }
            notch.focusRow(asks)
            expectEqual(record.acknowledgedSessions, [asks.id])
            expectEqual(record.acknowledgedRings, [], "the provider's other waiting session keeps asking")
            expectEqual(record.focused, [asks])
        },
        test("a ring double-click goes to the waiting session, else the most recent running one") { @MainActor in
            let record = FocusRecord()
            let asks = session(4103, "asks", state: .waiting, ago: 600)
            let newest = session(4101, "newest", ago: 5), older = session(4102, "older", ago: 50)
            guard let notch = notch([newest, older, asks], running: [4101, 4102, 4103], record: record) else {
                return expect(false, "needs a display")
            }
            notch.ringClicked("claudeCode", clickCount: 1, at: now)
            notch.ringClicked("claudeCode", clickCount: 2, at: now.addingTimeInterval(0.02))
            expectEqual(record.focused, [asks])

            let second = FocusRecord()
            guard let calm = FocusUITests.notch([newest, older], running: [4102], record: second) else { return }
            calm.ringClicked("claudeCode", clickCount: 1, at: now)
            calm.ringClicked("claudeCode", clickCount: 2, at: now.addingTimeInterval(0.02))
            expectEqual(second.focused, [older], "the newest has no running process, so the next one")
            try await afterTheInterval()
            expectEqual(record.refreshed + second.refreshed, [], "a double-click never refreshes")
        },
        test("a waiting ring: one click acknowledges; a double-click acknowledges and focuses") { @MainActor in
            let record = FocusRecord()
            let asks = session(4103, "asks", state: .waiting)
            guard let notch = notch([asks], asking: ["claudeCode"], running: [4103], record: record) else {
                return expect(false, "needs a display")
            }
            let readings = notch.model.snapshots
            notch.ringClicked("claudeCode", clickCount: 1, at: now)
            expectEqual(record.acknowledgedRings, ["claudeCode"])
            expectEqual(record.focused, [], "a single click only acknowledges")
            notch.ringClicked("claudeCode", clickCount: 2, at: now.addingTimeInterval(0.02))
            expectEqual(record.focused, [asks])
            expect(!notch.model.isExpanded, "folded once the session's app is forward")
            try await afterTheInterval()
            expectEqual(record.refreshed, [])
            expectEqual(notch.model.snapshots, readings, "the readings are untouched")
        },
        test("a quiet ring's single click still refreshes, once the interval has passed") { @MainActor in
            let record = FocusRecord()
            guard let notch = notch([session(4101, "brim")], running: [4101], record: record) else {
                return expect(false, "needs a display")
            }
            notch.ringClicked("codex", clickCount: 1)
            expectEqual(record.refreshed, [], "held while a second click could still come")
            try await afterTheInterval()
            expectEqual(record.refreshed, ["codex"])
            expectEqual(record.focused, [])

            notch.actions.ringClickAction = { .openUsagePage }
            notch.ringClicked("claudeCode", clickCount: 1)
            // A click on another ring ends the first sequence: its action runs at once.
            notch.ringClicked("codex", clickCount: 1)
            expectEqual(record.usagePages, ["claudeCode"])
            try await afterTheInterval()
            expectEqual(record.usagePages, ["claudeCode", "codex"])
        },
        test("Cursor's ring opens Cursor without any process id, and refreshes nothing") { @MainActor in
            let record = FocusRecord()
            guard let notch = notch([], running: [], record: record) else { return expect(false, "needs a display") }
            notch.ringClicked("manual.cursor", clickCount: 1, at: now)
            notch.ringClicked("manual.cursor", clickCount: 2, at: now.addingTimeInterval(0.02))
            expectEqual(record.openedApps, [.cursor])
            expectEqual(record.focused, [])
            try await afterTheInterval()
            expectEqual(record.refreshed, [])
        },
        test("Claude and Codex never invent a terminal: no running process means their own app") { @MainActor in
            let record = FocusRecord()
            let gone = [session(4101, "brim"), session(5101, "api", provider: "codex")]
            guard let notch = notch(gone, running: [], record: record) else { return expect(false, "needs a display") }
            for id in ["claudeCode", "codex"] {
                notch.model.isExpanded = true
                notch.ringClicked(id, clickCount: 1, at: now)
                notch.ringClicked(id, clickCount: 2, at: now.addingTimeInterval(0.02))
            }
            expectEqual(record.focused, [])
            expectEqual(record.openedApps, [.claude, .codex])
        },
        test("with focusing switched off, a double-click only acknowledges") { @MainActor in
            let record = FocusRecord()
            let asks = session(4103, "asks", state: .waiting)
            guard let notch = notch([asks], asking: ["claudeCode"], running: [4103], focusesSessions: false,
                                    record: record) else { return expect(false, "needs a display") }
            notch.ringClicked("claudeCode", clickCount: 1, at: now)
            notch.ringClicked("claudeCode", clickCount: 2, at: now.addingTimeInterval(0.02))
            notch.focusRow(asks)
            expectEqual(record.acknowledgedRings, ["claudeCode", "claudeCode"])
            expectEqual(record.focused, [])
            expectEqual(record.openedApps, [])
            try await afterTheInterval()
            expectEqual(record.refreshed, [])
        },
    ])

    // MARK: - From a process id to a terminal tab

    typealias Entry = SessionFocus.ProcessEntry

    static func processes(_ table: [pid_t: Entry], apps: [pid_t: String], running: [String: pid_t] = [:],
                          alive: Set<pid_t>? = nil) -> SessionFocus.Processes {
        SessionFocus.Processes(isRunning: { alive?.contains($0) ?? (table[$0] != nil) }, entry: { table[$0] },
                               regularApp: { apps[$0] }, runningApp: { running[$0] })
    }

    static let processSuite = TestSuite("Finding a session's terminal", [
        test("a Claude Code session in Terminal: its own tab, by its device") {
            let table: [pid_t: Entry] = [
                4101: Entry(parent: 4100, name: "claude", device: "/dev/ttys000"),
                4100: Entry(parent: 4099, name: "-zsh", device: "/dev/ttys000"),
                4099: Entry(parent: 400, name: "login", device: "/dev/ttys000"),
                4201: Entry(parent: 4200, name: "claude", device: "/dev/ttys001"),
                4200: Entry(parent: 4199, name: "-zsh", device: "/dev/ttys001"),
                4199: Entry(parent: 400, name: "login", device: "/dev/ttys001"),
                400: Entry(parent: nil, name: "Terminal", device: nil),
            ]
            let terminal = processes(table, apps: [400: "com.apple.Terminal"])
            expectEqual(SessionFocus.plan(for: 4101, in: terminal), .selectTab(device: "/dev/ttys000", terminal: .terminal, app: 400))
            expectEqual(SessionFocus.plan(for: 4201, in: terminal), .selectTab(device: "/dev/ttys001", terminal: .terminal, app: 400))
        },
        test("a Codex session in iTerm2, whose sessions run under its server") {
            let table: [pid_t: Entry] = [
                5101: Entry(parent: 5100, name: "codex", device: "/dev/ttys004"),
                5100: Entry(parent: 5050, name: "zsh", device: "/dev/ttys004"),
                5050: Entry(parent: nil, name: "iTermServer-3.5.", device: nil),
            ]
            let iTerm = processes(table, apps: [:], running: ["com.googlecode.iterm2": 600])
            expectEqual(SessionFocus.plan(for: 5101, in: iTerm), .selectTab(device: "/dev/ttys004", terminal: .iTerm, app: 600))
        },
        test("sessions in the Codex app or an editor bring that app forward") {
            let table: [pid_t: Entry] = [
                13928: Entry(parent: 700, name: "codex", device: nil),
                700: Entry(parent: nil, name: "ChatGPT", device: nil),
                8101: Entry(parent: 8100, name: "claude", device: "/dev/ttys009"),
                8100: Entry(parent: 8050, name: "zsh", device: "/dev/ttys009"),
                8050: Entry(parent: 800, name: "Cursor Helper (", device: nil),
                800: Entry(parent: nil, name: "Cursor", device: nil),
            ]
            let apps = processes(table, apps: [700: "com.openai.codex", 800: "com.todesktop.230313mzl4w4u92"])
            expectEqual(SessionFocus.plan(for: 13928, in: apps), .bringForward(app: 700))
            expectEqual(SessionFocus.plan(for: 8101, in: apps), .bringForward(app: 800))
        },
        test("a process that has gone, or that no app hosts, gives nothing to raise") {
            let table: [pid_t: Entry] = [
                4101: Entry(parent: 4100, name: "claude", device: "/dev/ttys000"),
                4100: Entry(parent: 400, name: "-zsh", device: "/dev/ttys000"),
                400: Entry(parent: nil, name: "Terminal", device: nil),
                9101: Entry(parent: 9100, name: "claude", device: "/dev/ttys012"),
                9100: Entry(parent: 9000, name: "zsh", device: "/dev/ttys012"),
                9000: Entry(parent: nil, name: "tmux", device: nil),
            ]
            // The terminal was closed: its session's process went with it.
            let closed = processes(table, apps: [400: "com.apple.Terminal"], alive: [400, 9101, 9100, 9000])
            expectEqual(SessionFocus.plan(for: 4101, in: closed), .nothing)
            expectEqual(SessionFocus.plan(for: 4242, in: closed), .nothing)
            // Detached under tmux: no terminal is guessed at.
            expectEqual(SessionFocus.plan(for: 9101, in: closed), .nothing)
        },
        test("only a /dev/ttys path ever reaches a terminal's script") {
            expect(SessionFocus.isTerminalDevice("/dev/ttys000"))
            expect(SessionFocus.isTerminalDevice("/dev/ttys12345"))
            for bad in ["/dev/console", "ttys001", "/dev/ttys001\" & do shell script \"true", "/dev/ttys001\n", ""] {
                expect(!SessionFocus.isTerminalDevice(bad), bad)
            }
            let table: [pid_t: Entry] = [
                4101: Entry(parent: 400, name: "claude", device: "/dev/ttys001\" & do shell script \"true"),
                400: Entry(parent: nil, name: "Terminal", device: nil),
            ]
            expectEqual(SessionFocus.plan(for: 4101, in: processes(table, apps: [400: "com.apple.Terminal"])),
                        .bringForward(app: 400))
        },
        test("the tab scripts ask for device names and select; they never read a tab") {
            for terminal in SessionFocus.ScriptableTerminal.allCases {
                let script = SessionFocus.selectionScript(device: "/dev/ttys003", terminal: terminal)
                expect(script.contains("tty of") && script.contains("\"/dev/ttys003\""), terminal.rawValue)
                expect(script.contains("is not running then return false"), "never launches \(terminal.rawValue)")
                for reading in ["contents", "history", "text of", "do shell script", "write text"] {
                    expect(!script.contains(reading), "\(terminal.rawValue) script reads or runs: \(reading)")
                }
            }
        },
        test("the kernel reads this process's own parent, name and running state") {
            let me = getpid()
            let entry = SessionFocus.kernelEntry(me)
            expectEqual(entry?.parent, getppid() > 1 ? getppid() : nil)
            expect(entry.map { !$0.name.isEmpty } ?? false)
            expect(SessionFocus.isRunning(me))
            expect(!SessionFocus.isRunning(0) && !SessionFocus.isRunning(-1))
        },
    ])
}
