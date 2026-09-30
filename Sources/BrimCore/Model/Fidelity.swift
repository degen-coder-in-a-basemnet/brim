import Foundation

/// How much a reading can be trusted, declared by the adapter that produced it.
///
/// The UI prints this rather than inferring it, so a number Brim worked out for
/// itself can never be mistaken for one the vendor published.
public enum Fidelity: String, Codable, CaseIterable, Sendable {
    /// Reported by the vendor: a usage endpoint, or a server-reported figure
    /// that the vendor's own tool recorded on disk.
    case official
    /// Worked out by Brim from local records, such as token counts in session
    /// logs. Always shown with a `~`.
    case derived
    /// Typed in by the user. Exactly as accurate as what was entered.
    case manual
    /// A runtime on this Mac with no quota to report; readings are
    /// measurements of the machine, not of an allowance.
    case local
    /// No safe way to read this provider. Shown as a status, never a number.
    case unsupported

    /// Prefix for a percentage Brim estimated rather than read.
    public var qualifier: String { self == .derived ? "≈" : "" }

    public var title: String {
        switch self {
        case .official:    return "Official"
        case .derived:     return "Estimated"
        case .manual:      return "Manual"
        case .local:       return "Local"
        case .unsupported: return "Unsupported"
        }
    }

    public var explanation: String {
        switch self {
        case .official:
            return "Reported by the provider."
        case .derived:
            return "Estimated by Brim from local logs. Not the provider's own figure."
        case .manual:
            return "Entered by you in Settings."
        case .local:
            return "Measured from a runtime on this Mac. There is no quota."
        case .unsupported:
            return "This provider has no safe local source."
        }
    }
}
