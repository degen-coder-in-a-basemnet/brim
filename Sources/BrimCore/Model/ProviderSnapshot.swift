import Foundation

/// Everything one provider's ring and tooltip show, at one moment.
public struct ProviderSnapshot: Identifiable, Equatable, Sendable {
    /// The provider instance, e.g. "claudeCode" or "manual.3F2A…".
    public var id: String
    public var kind: ProviderKind
    public var displayName: String
    public var glyph: ProviderGlyph
    public var fidelity: Fidelity
    public var windows: [LimitWindow]
    /// When the figures were true — not when Brim fetched them. A figure read
    /// from a log is as old as the log line.
    public var capturedAt: Date?
    public var status: ProviderStatus
    /// One line on where the figures came from, shown under the windows.
    public var source: String?
    /// The account's plan name, when the source prints one.
    public var plan: String?
    /// Replaces the percentage under the ring, for providers with no quota
    /// (a local runtime shows how many models it has loaded).
    public var cellLabel: String?
    /// When set, the ring shows this window instead of the most constrained.
    public var preferredHeadlineID: String?

    public init(id: String, kind: ProviderKind, displayName: String, glyph: ProviderGlyph,
                fidelity: Fidelity, windows: [LimitWindow] = [], capturedAt: Date? = nil,
                status: ProviderStatus = .ok, source: String? = nil, plan: String? = nil,
                cellLabel: String? = nil, preferredHeadlineID: String? = nil) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.glyph = glyph
        self.fidelity = fidelity
        self.windows = windows
        self.capturedAt = capturedAt
        self.status = status
        self.source = source
        self.plan = plan
        self.cellLabel = cellLabel
        self.preferredHeadlineID = preferredHeadlineID
    }

    /// The window the ring draws: the most constrained one, because the
    /// question the ring answers is "am I about to be cut off".
    public var headline: LimitWindow? {
        if let preferredHeadlineID, let preferred = windows.first(where: { $0.id == preferredHeadlineID }),
           preferred.usedFraction != nil {
            return preferred
        }
        let measured = windows.filter { $0.usedFraction != nil }
        return measured.max { ($0.usedFraction ?? 0) < ($1.usedFraction ?? 0) } ?? windows.first
    }

    public var usedFraction: Double? { headline?.usedFraction }

    /// True when there is a percentage to draw.
    public var hasReading: Bool { usedFraction != nil }

    /// Fidelity of the headline figure: a window may be more trustworthy than
    /// the provider's default.
    public var headlineFidelity: Fidelity { headline?.fidelity ?? fidelity }

    /// The text under the ring. A dash, not "0%", when nothing was read:
    /// nothing read is not the same as nothing used.
    public var headlineText: String {
        if let cellLabel { return cellLabel }
        guard let fraction = usedFraction else { return "—" }
        return Percent.text(for: fraction)
    }

    /// Any window spent and not yet reset.
    public func isBlocked(now: Date) -> Bool {
        windows.contains { $0.isExhausted(now: now) }
    }

    /// The spent window, for the "blocked until" line.
    public func blockingWindow(now: Date) -> LimitWindow? {
        windows.first { $0.isExhausted(now: now) }
    }

    /// The same reading, marked as remembered rather than live.
    public func markedStale(since: Date) -> ProviderSnapshot {
        var copy = self
        if !status.isProblem { copy.status = .stale(since: since) }
        return copy
    }
}
