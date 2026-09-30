import Foundation

/// One metered allowance: the rolling session window, the weekly cap, a plan's
/// monthly requests. A provider reports as many as it has.
public struct LimitWindow: Identifiable, Codable, Equatable, Sendable {
    /// Stable within a provider, so readings from different sources line up.
    public var id: String
    public var label: String
    /// Share of the allowance spent, 0...1 (may exceed 1 briefly). Nil when the
    /// source says how much was used but never out of what: no denominator, no
    /// ring and no bar, rather than one drawn against a guess.
    public var usedFraction: Double?
    public var resetsAt: Date?
    /// Length of the window, when known (5 h, 7 d).
    public var duration: TimeInterval?
    /// Replaces or extends the "N% Used" line, e.g. "4.1M tokens".
    public var detail: String?
    /// Set when this window's figure is more or less trustworthy than the
    /// provider's own default — an official 429 inside a derived provider.
    public var fidelity: Fidelity?
    /// A quiet second line, e.g. "Limit hit at 14:02".
    public var note: String?

    public init(id: String, label: String, usedFraction: Double? = nil, resetsAt: Date? = nil,
                duration: TimeInterval? = nil, detail: String? = nil, fidelity: Fidelity? = nil,
                note: String? = nil) {
        self.id = id
        self.label = label
        self.usedFraction = usedFraction
        self.resetsAt = resetsAt
        self.duration = duration
        self.detail = detail
        self.fidelity = fidelity
        self.note = note
    }

    /// Whole-number percent, never below zero. 100 means spent.
    public var percent: Int? {
        usedFraction.map { Percent.value(for: $0) }
    }

    /// True when the allowance is spent and has not rolled over yet.
    public func isExhausted(now: Date) -> Bool {
        guard let usedFraction, usedFraction >= 1 else { return false }
        guard let resetsAt else { return true }
        return resetsAt > now
    }

    /// A count-only row: a value with nothing to be a share of.
    public var isCountRow: Bool {
        usedFraction == nil && resetsAt == nil && detail != nil
    }
}

public enum Percent {
    /// Rounded half-up, clamped at zero. 0.995 reads 100: a limit one request
    /// from spent should not show a comforting 99.
    public static func value(for fraction: Double) -> Int {
        guard fraction.isFinite else { return 0 }
        return max(0, Int((fraction * 100).rounded()))
    }

    public static func text(for fraction: Double) -> String {
        "\(value(for: fraction))%"
    }
}
