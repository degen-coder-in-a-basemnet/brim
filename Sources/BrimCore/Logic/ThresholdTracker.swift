// Crossing rules adapted from Codenotch (https://github.com/vinzdg/codenotch),
// MIT License, Copyright (c) 2026 Vinz. See THIRD_PARTY_NOTICES.md.
import Foundation

/// One alert-worthy crossing of a provider's headline limit.
public struct ThresholdAlert: Equatable, Sendable {
    /// 80 or 100.
    public let threshold: Int
    public let providerID: String
    public let providerName: String
    public let windowLabel: String
    public let usedPercent: Int
    public let resetsAt: Date?
    public let fidelity: Fidelity

    public var title: String {
        threshold >= 100 ? "\(providerName) limit reached" : "\(providerName) is at \(fidelity.qualifier)\(usedPercent)%"
    }

    public var body: String {
        let window = windowLabel.lowercased()
        if threshold >= 100 {
            if let resetsAt {
                let time = resetsAt.formatted(date: .omitted, time: .shortened)
                return "Its \(window) limit is spent. Resets at \(time)."
            }
            return "Its \(window) limit is spent."
        }
        return "\(fidelity.qualifier)\(usedPercent)% of its \(window) limit used."
    }
}

/// Reports the moment a provider's headline limit crosses 80% or reaches 100%.
///
/// Crossing, not level: a provider parked at 91% alerts once. The highest level
/// crossed is remembered per provider and forgotten when the reading falls back
/// below 80% — the window rolled over, and the next climb is news again.
/// The first reading of a provider only records: at launch every provider
/// arrives with no history, and treating that as a crossing would alert on
/// every start. Stale readings are not a baseline either.
public final class ThresholdTracker {
    public static let thresholds = [80, 100]
    private var crossed: [String: Int] = [:]

    public init() {}

    public func observe(_ snapshots: [ProviderSnapshot], isMuted: (String) -> Bool = { _ in false }) -> [ThresholdAlert] {
        snapshots.flatMap { observe($0, muted: isMuted($0.id)) }
    }

    public func forget(_ providerID: String) {
        crossed.removeValue(forKey: providerID)
    }

    private func observe(_ snapshot: ProviderSnapshot, muted: Bool) -> [ThresholdAlert] {
        guard !snapshot.status.isStale, !snapshot.status.isProblem else {
            crossed.removeValue(forKey: snapshot.id)
            return []
        }
        guard let headline = snapshot.headline, let fraction = headline.usedFraction else { return [] }
        let percent = fraction * 100
        let level = percent >= 100 ? 100 : percent >= 80 ? 80 : 0

        guard let previous = crossed[snapshot.id] else {
            crossed[snapshot.id] = level
            return []
        }
        crossed[snapshot.id] = level
        guard level > previous, !muted else { return [] }

        return Self.thresholds.filter { $0 > previous && $0 <= level }.map { threshold in
            ThresholdAlert(threshold: threshold,
                           providerID: snapshot.id,
                           providerName: snapshot.displayName,
                           windowLabel: headline.label,
                           usedPercent: Percent.value(for: fraction),
                           resetsAt: headline.resetsAt,
                           fidelity: headline.fidelity ?? snapshot.fidelity)
        }
    }
}
