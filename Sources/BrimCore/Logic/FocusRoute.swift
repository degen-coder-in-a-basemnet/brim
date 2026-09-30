import Foundation

/// A provider's own app: where a ring double-click goes when none of the
/// provider's sessions has a running process to follow. Only apps whose
/// identity is certain, by bundle identifier.
public struct ProviderApp: Equatable, Sendable {
    public let bundleID: String
    /// Opened when it isn't running. Otherwise it is brought forward only if it
    /// already runs: Claude Code and Codex live mostly in terminals, so opening
    /// their desktop apps would be a guess.
    public let opens: Bool

    public init(bundleID: String, opens: Bool) {
        self.bundleID = bundleID
        self.opens = opens
    }

    public static let cursor = ProviderApp(bundleID: "com.todesktop.230313mzl4w4u92", opens: true)
    public static let codex = ProviderApp(bundleID: "com.openai.codex", opens: false)
    public static let claude = ProviderApp(bundleID: "com.anthropic.claudefordesktop", opens: false)

    /// The app behind a ring. Cursor has no provider of its own, so Manual and
    /// demo rings go by name: a Manual provider called "Cursor" is Cursor's ring.
    public static func of(kind: ProviderKind, name: String) -> ProviderApp? {
        switch kind {
        case .claudeCode: return .claude
        case .codex:      return .codex
        case .manual, .demo:
            switch name.trimmingCharacters(in: .whitespaces).lowercased() {
            case "cursor":      return .cursor
            case "claude code": return .claude
            case "codex":       return .codex
            default:            return nil
            }
        case .ollama, .lmStudio: return nil
        }
    }
}

/// Where a click on a session row, or a double-click on a ring, takes you.
/// Pure, so the choice can be tested without a process in sight.
public enum FocusRoute: Equatable, Sendable {
    /// The app hosting this session's process, at its tab where the terminal allows.
    case session(AgentSession)
    /// The provider's own app.
    case app(ProviderApp)
    /// Nothing that can be brought forward with certainty.
    case none

    /// A session row: that session, through its own process, or nothing. Never
    /// another session, however recent.
    public static func forRow(_ session: AgentSession, isRunning: (Int32) -> Bool) -> FocusRoute {
        guard let pid = session.processID, isRunning(pid) else { return .none }
        return .session(session)
    }

    /// A ring double-click: its waiting session, else its most recently active
    /// one — the first the card lists (waiting, then working, newest first)
    /// whose process still runs — else the provider's own app. `remembered` is
    /// the waiting session the double-click's first click acknowledged.
    public static func forRing(_ sessions: [AgentSession], preferring remembered: AgentSession? = nil,
                               app: ProviderApp?, isRunning: (Int32) -> Bool) -> FocusRoute {
        func runs(_ session: AgentSession) -> Bool { session.processID.map(isRunning) ?? false }
        if let remembered, remembered.state == .waiting, runs(remembered) { return .session(remembered) }
        if let session = ActivitySummary(sessions: sessions).ordered.first(where: runs) { return .session(session) }
        return app.map(FocusRoute.app) ?? .none
    }
}
