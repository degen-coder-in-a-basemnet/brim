import os

/// Brim's only logging. Unified logging stays on this Mac, and Brim writes to
/// it sparingly: provider ids, counts, durations and status words. Never a
/// path's contents, a response, a prompt, or anything a user typed.
///
/// Interpolated values are private unless marked `.public`, and the privacy
/// audit (scripts/privacy-audit.sh) lists every `.public` for review.
public enum SafeLog {
    public static let store = Logger(subsystem: "local.brim.Brim", category: "store")
    public static let providers = Logger(subsystem: "local.brim.Brim", category: "providers")
    public static let ui = Logger(subsystem: "local.brim.Brim", category: "ui")
}
