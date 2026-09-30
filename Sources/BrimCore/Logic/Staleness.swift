import Foundation

/// When a figure stops being presented as live.
public enum Staleness {
    /// How old a provider's figures may be before they are dimmed.
    ///
    /// Polled sources get three missed polls, and never less than ten minutes.
    /// Codex's figures are only as new as its last request, so they dim after
    /// half an hour of no Codex activity. Manual figures are whatever was typed
    /// and never go stale on their own.
    public static func maxAge(for kind: ProviderKind, refreshInterval: TimeInterval) -> TimeInterval {
        switch kind {
        case .manual, .demo: return .infinity
        case .codex:         return 30 * 60
        default:             return max(3 * refreshInterval, 10 * 60)
        }
    }

    public static func isStale(capturedAt: Date?, now: Date, maxAge: TimeInterval) -> Bool {
        guard let capturedAt, maxAge.isFinite else { return false }
        return now.timeIntervalSince(capturedAt) > maxAge
    }

    /// Marks a snapshot stale if its figures are older than allowed. Problem
    /// states are left alone: they already say what is wrong.
    public static func evaluate(_ snapshot: ProviderSnapshot, now: Date, maxAge: TimeInterval) -> ProviderSnapshot {
        guard snapshot.status == .ok,
              isStale(capturedAt: snapshot.capturedAt, now: now, maxAge: maxAge),
              let capturedAt = snapshot.capturedAt
        else { return snapshot }
        return snapshot.markedStale(since: capturedAt)
    }
}
