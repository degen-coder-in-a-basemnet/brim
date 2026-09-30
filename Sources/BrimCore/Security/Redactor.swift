import Foundation

/// Scrubs anything that looks like a credential out of text before it can be
/// shown, logged or saved.
///
/// Brim never asks for secrets, but error text from a local server or a CLI can
/// echo one back (a proxy URL with a password, a header in a stack trace).
/// Every message that reaches a status line passes through here first.
public enum Redactor {
    private static let patterns: [NSRegularExpression] = [
        // Vendor key shapes: sk-…, sk-ant-…, sk-proj-…, pk_…, ghp_…, xox…-
        #"\b(?:sk|pk|rk)[-_](?:ant[-_]|proj[-_]|live[-_]|test[-_])?[A-Za-z0-9_\-]{12,}"#,
        #"\bgh[pousr]_[A-Za-z0-9]{20,}"#,
        #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#,
        #"\bAIza[0-9A-Za-z_\-]{20,}"#,
        // JWTs.
        #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#,
        // Authorization headers and cookie values.
        #"(?i)\b(bearer|basic|token)\s+[A-Za-z0-9._~+/\-=]{8,}"#,
        #"(?i)\b(authorization|cookie|set-cookie|x-api-key|api[-_]?key|access[-_]?token|refresh[-_]?token|secret|password|passwd)\b\s*[:=]\s*("[^"]*"|'[^']*'|[^\s,;]+)"#,
        #"(?i)"(access_token|refresh_token|id_token|api_key|apiKey|token|secret|password)"\s*:\s*"[^"]*""#,
        // Credentials inside URLs.
        #"(?i)(?<=://)[^/\s:@]+:[^/\s@]+(?=@)"#,
        // Long opaque blobs: hex or base64 runs that no status message needs.
        #"\b[A-Fa-f0-9]{40,}\b"#,
        #"\b[A-Za-z0-9+/]{48,}={0,2}"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    public static let marker = "[redacted]"

    public static func redact(_ text: String) -> String {
        var result = text
        for pattern in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: marker)
        }
        return result
    }

    /// Redacts and shortens, for one-line status messages.
    public static func statusLine(_ text: String, limit: Int = 160) -> String {
        let flat = redact(text).replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}
