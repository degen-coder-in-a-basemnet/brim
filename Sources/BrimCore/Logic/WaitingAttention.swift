import Foundation

/// Which agents are waiting on the person and haven't been answered or
/// acknowledged: the rings that ask for attention, holding the notch open until
/// clicked.
///
/// The unit is a waiting *episode*: one session in one stretch of waiting, told
/// apart by when that stretch began. So a session that is acknowledged,
/// answered, then stops to ask again alerts again, even if a poll missed the
/// moment in between. Like session announcements, whatever is already waiting
/// the first time Brim looks counts as seen: launching is not news.
public struct WaitingAttention: Equatable, Sendable {
    public struct Episode: Hashable, Sendable {
        public let providerID: String
        public let sessionID: String
        public let since: Date
    }

    /// Every waiting episode at the last look.
    private var current: Set<Episode> = []
    /// The ones still asking: not yet acknowledged.
    private var asking: Set<Episode> = []
    private var hasLooked = false

    public init() {}

    /// Takes one poll's sessions. Returns the providers that have just started
    /// asking.
    @discardableResult
    public mutating func observe(_ activity: [String: ActivitySummary]) -> Set<String> {
        var waiting: Set<Episode> = []
        for summary in activity.values {
            for session in summary.sessions where session.state == .waiting {
                waiting.insert(Episode(providerID: session.providerID, sessionID: session.id, since: session.since))
            }
        }
        let fresh = hasLooked ? waiting.subtracting(current) : []
        // Answered, finished or gone: an episode no longer waiting stops asking,
        // and forgetting it lets the next one ask.
        asking = asking.intersection(waiting).union(fresh)
        current = waiting
        hasLooked = true
        return Set(fresh.map(\.providerID))
    }

    /// Providers with a waiting session nobody has acknowledged.
    public var providers: Set<String> { Set(asking.map(\.providerID)) }

    public func isAsking(_ providerID: String) -> Bool {
        asking.contains { $0.providerID == providerID }
    }

    /// This provider's waiting sessions have been seen: they stop asking. Other
    /// providers keep asking, and a later episode asks afresh.
    public mutating func acknowledge(providerID: String) {
        asking = asking.filter { $0.providerID != providerID }
    }

    /// One session has been seen, from its row in a card: it stops asking. The
    /// provider's other waiting sessions keep asking.
    public mutating func acknowledge(sessionID: String) {
        asking = asking.filter { $0.sessionID != sessionID }
    }

    /// The session a double-click should bring forward: the newest waiting one
    /// of that provider, preferring one whose process is known.
    public static func focusTarget(providerID: String, in activity: [String: ActivitySummary]) -> AgentSession? {
        let waiting = (activity[providerID]?.sessions ?? [])
            .filter { $0.state == .waiting }
            .sorted { $0.since > $1.since }
        return waiting.first { $0.processID != nil } ?? waiting.first
    }
}
