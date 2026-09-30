import Foundation

/// The colour state of a ring or bar.
///
/// Thresholds follow the reference design frame, which shows 21% green, 52%
/// yellow and 73% orange — so yellow starts at 50% and orange at 70%.
public enum UsageBand: String, Codable, Equatable, Sendable {
    case ample       // plenty of room
    case watch       // getting close
    case critical    // nearly out
    case exhausted   // spent, waiting for the reset

    public static let defaultWatchLimit = 0.50
    public static let defaultCriticalLimit = 0.70

    public static func band(for usedFraction: Double,
                            watchLimit: Double = defaultWatchLimit,
                            criticalLimit: Double = defaultCriticalLimit) -> UsageBand {
        switch usedFraction {
        case ..<watchLimit:    return .ample
        case ..<criticalLimit: return .watch
        case ..<1.0:           return .critical
        default:               return .exhausted
        }
    }
}
