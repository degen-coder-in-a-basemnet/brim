import Foundation

/// What an agent session is doing, as far as its own records say.
public enum SessionState: String, Codable, CaseIterable, Sendable {
    /// Working on a turn.
    case busy
    /// Stopped and waiting on you: a permission prompt or a question.
    case waiting
    /// Just finished a turn. Decays to `idle` after a short while.
    case finished
    /// Open and doing nothing.
    case idle
    /// Claims to be working, but its record stopped updating long ago.
    case stale
    /// The provider cannot see its sessions right now.
    case unavailable

    /// Which state wins when several sessions share one ring: the one that
    /// wants you, then the one working, then the one that just finished.
    var priority: Int {
        switch self {
        case .waiting:     return 0
        case .busy:        return 1
        case .finished:    return 2
        case .stale:       return 3
        case .idle:        return 4
        case .unavailable: return 5
        }
    }

    public var word: String {
        switch self {
        case .busy:        return "working"
        case .waiting:     return "waiting"
        case .finished:    return "finished"
        case .idle:        return "idle"
        case .stale:       return "stale"
        case .unavailable: return "unavailable"
        }
    }
}

public struct AgentSession: Identifiable, Equatable, Sendable {
    public var id: String
    public var providerID: String
    /// The session's title when shown, otherwise its folder.
    public var name: String
    /// Where it runs, e.g. "Terminal · brim".
    public var detail: String
    public var state: SessionState
    /// When `state` began.
    public var since: Date
    /// The agent's process, used only to raise the app that hosts it.
    public var processID: Int32?
    /// What a waiting session is waiting for, when the record says.
    public var waitingFor: String?

    public init(id: String, providerID: String, name: String, detail: String, state: SessionState,
                since: Date, processID: Int32? = nil, waitingFor: String? = nil) {
        self.id = id
        self.providerID = providerID
        self.name = name
        self.detail = detail
        self.state = state
        self.since = since
        self.processID = processID
        self.waitingFor = waitingFor
    }
}

/// Every live session for one provider, reduced to the one state its ring shows.
public struct ActivitySummary: Equatable, Sendable {
    public var sessions: [AgentSession]

    public init(sessions: [AgentSession]) {
        self.sessions = sessions
    }

    /// The most urgent state across sessions; `idle` when there are none.
    public var state: SessionState {
        sessions.map(\.state).min { $0.priority < $1.priority } ?? .idle
    }

    /// Sessions ordered for display: waiting first, then working, newest first
    /// within a state.
    public var ordered: [AgentSession] {
        sessions.sorted {
            $0.state.priority == $1.state.priority ? $0.since > $1.since : $0.state.priority < $1.state.priority
        }
    }

    public var isEmpty: Bool { sessions.isEmpty }
}
