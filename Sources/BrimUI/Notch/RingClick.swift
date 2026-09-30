import Foundation

/// What a left click on the notch means for its rings. Pure, so the
/// double-click rules can be tested without a window.
///
/// A click sequence is what AppKit counts as one: clicks that follow each other
/// within the double-click interval. A second click on the ring a sequence began
/// on is a double-click on that ring. No click after a sequence's first is ever
/// a single-click action, so a double-click never refreshes.
enum RingClick: Equatable {
    /// A first click on an asking ring: it stops asking at once. Nothing else:
    /// no refresh, no page.
    case acknowledge(String)
    /// A first click on a quiet ring: its click action, held until the
    /// double-click interval has passed, because a second click cancels it.
    case single(String)
    /// A second click on the same ring: it stops asking, and its session or
    /// app comes forward.
    case focus(String)
    /// A later click of a sequence: nothing at all.
    case ignore
    /// Not on a ring: the notch's own click.
    case ordinary

    static func outcome(ringID: String?, clickCount: Int, asking: Set<String>,
                        sequence: (providerID: String, at: Date)?, now: Date,
                        doubleClickInterval: TimeInterval) -> RingClick {
        if clickCount >= 2, let sequence, now.timeIntervalSince(sequence.at) <= doubleClickInterval {
            // The rest of a sequence begun on a ring. The first click of a
            // double-click on an asking ring has acknowledged it, so it is no
            // longer asking by the second: still a double-click on it.
            return clickCount == 2 && ringID == sequence.providerID ? .focus(sequence.providerID) : .ignore
        }
        guard let ringID else { return .ordinary }
        if clickCount >= 2 {
            // A sequence begun off this ring. An asking ring double-clicked
            // straight on still goes to its session; a quiet one never
            // refreshes partway through someone else's double-click.
            return clickCount == 2 && asking.contains(ringID) ? .focus(ringID) : .ignore
        }
        return asking.contains(ringID) ? .acknowledge(ringID) : .single(ringID)
    }
}
