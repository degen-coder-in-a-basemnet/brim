import Foundation

/// A session changing state in a way worth interrupting for.
public struct SessionEvent: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// Stopped working: the turn is done.
        case finished
        /// Stopped to ask you something.
        case waiting
    }

    public let kind: Kind
    public let session: AgentSession
    public let providerName: String

    public var title: String {
        switch kind {
        case .finished: return "\(providerName) finished"
        case .waiting:  return "\(providerName) is waiting for you"
        }
    }

    public var body: String {
        if kind == .waiting, let waitingFor = session.waitingFor, !waitingFor.isEmpty {
            return "\(session.name): \(waitingFor)"
        }
        return session.name
    }
}

/// Turns successive session lists into events.
///
/// Only *leaving* busy counts as finishing. A session seen for the first time
/// arrives with no history, so it announces nothing — otherwise every session
/// already open at launch would ring. A session that vanishes is not
/// announced either: that is what quitting the agent looks like.
public final class SessionTransitionDetector {
    private var last: [String: SessionState] = [:]

    public init() {}

    public func observe(_ sessions: [AgentSession], providerName: (String) -> String) -> [SessionEvent] {
        var events: [SessionEvent] = []
        var next: [String: SessionState] = [:]
        for session in sessions {
            next[session.id] = session.state
            guard let previous = last[session.id], previous != session.state else { continue }
            let name = providerName(session.providerID)
            switch (previous, session.state) {
            case (.busy, .finished), (.busy, .idle):
                events.append(SessionEvent(kind: .finished, session: session, providerName: name))
            case (_, .waiting) where previous != .waiting:
                events.append(SessionEvent(kind: .waiting, session: session, providerName: name))
            default:
                break
            }
        }
        last = next
        return events
    }

    public func reset() { last = [:] }
}
