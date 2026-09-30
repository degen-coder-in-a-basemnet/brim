import Foundation

/// The health of a provider's latest reading. Every failure lands here as a
/// visible state instead of turning into a made-up percentage.
public enum ProviderStatus: Equatable, Sendable {
    case ok
    /// A remembered reading, still shown but dimmed, dated from `since`.
    case stale(since: Date)
    /// The provider needs a sign-in Brim will not perform on its own.
    case needsAuth(String)
    /// The source is absent: not installed, not running, nothing logged yet.
    case unavailable(String)
    /// The source answered with something Brim could not use. Always redacted.
    case error(String)
    /// No safe way to read this provider at all.
    case unsupported(String)

    public var isStale: Bool {
        if case .stale = self { return true }
        return false
    }

    public var staleSince: Date? {
        if case .stale(let since) = self { return since }
        return nil
    }

    /// True for the states that carry no usable reading of their own.
    public var isProblem: Bool {
        switch self {
        case .ok, .stale: return false
        default: return true
        }
    }

    public var message: String? {
        switch self {
        case .ok, .stale: return nil
        case .needsAuth(let text), .unavailable(let text), .error(let text), .unsupported(let text):
            return text
        }
    }

    /// A short word for the tooltip header and accessibility.
    public var label: String {
        switch self {
        case .ok:          return "Live"
        case .stale:       return "Stale"
        case .needsAuth:   return "Needs authentication"
        case .unavailable: return "Unavailable"
        case .error:       return "Error"
        case .unsupported: return "Unsupported"
        }
    }
}
