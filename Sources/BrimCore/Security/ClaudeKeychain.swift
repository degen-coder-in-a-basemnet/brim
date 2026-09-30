// Keychain lookup (newest item by modification date, via persistent reference)
// adapted from Codenotch (https://github.com/vinzdg/codenotch), MIT License,
// Copyright (c) 2026 Vinz. See THIRD_PARTY_NOTICES.md.
import Foundation
import Security

/// Claude Code's sign-in, as much of it as Brim ever holds: the access token,
/// when it expires, and the plan name. Only ever in memory. Every description
/// of it, printed or dumped, leaves the token out.
struct ClaudeOAuthCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let accessToken: String
    let expiresAt: Date
    /// "pro", "max", … as Claude Code files it.
    let plan: String?

    func isExpired(at now: Date) -> Bool { expiresAt <= now }

    var description: String {
        "ClaudeOAuthCredential(token: [redacted], expires: \(expiresAt), plan: \(plan ?? "unknown"))"
    }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["expiresAt": expiresAt, "plan": plan as Any], displayStyle: .struct)
    }

    /// The item Claude Code files is `{"claudeAiOauth": {"accessToken", "refreshToken",
    /// "expiresAt" (ms), "subscriptionType", …}}`. Only three fields are named,
    /// so the refresh token is never decoded: Brim does not renew sign-ins.
    static func decode(_ data: Data) throws -> ClaudeOAuthCredential {
        struct Payload: Decodable {
            struct OAuth: Decodable {
                let accessToken: String
                let expiresAt: Double
                let subscriptionType: String?
            }
            let claudeAiOauth: OAuth
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw ClaudeCredentialError.unreadable
        }
        // Claude Code empties the item when it signs out rather than deleting it.
        guard !payload.claudeAiOauth.accessToken.isEmpty else { throw ClaudeCredentialError.signedOut }
        return ClaudeOAuthCredential(accessToken: payload.claudeAiOauth.accessToken,
                                     expiresAt: Date(timeIntervalSince1970: payload.claudeAiOauth.expiresAt / 1000),
                                     plan: payload.claudeAiOauth.subscriptionType)
    }
}

enum ClaudeCredentialError: Error, Equatable {
    /// Nothing filed: Claude Code has not signed in on this Mac.
    case notFound
    /// The person asked, or macOS, said no.
    case denied
    /// macOS could not ask just now (for instance straight after waking).
    case notNow
    /// Claude Code signed out and left the item empty.
    case signedOut
    /// Not in the shape Claude Code writes.
    case unreadable
}

/// Where Claude Code keeps its sign-in.
protocol ClaudeCredentialStore: Sendable {
    /// The newest sign-in. Only ever called because someone clicked, so macOS
    /// may ask them first.
    func read() throws -> ClaudeOAuthCredential
}

/// The login keychain, through Security.framework. The only code in Brim that
/// touches the keychain, and it only reads: `SecItemCopyMatching`, never an
/// add, update or delete.
///
/// Claude Code files a fresh item under the same name each time it renews its
/// sign-in, so several can pile up and the newest is the live one. Finding it
/// reads attributes only, which needs no permission. Only the final fetch of
/// that one item's data does, and macOS asks the person before allowing it.
struct SystemClaudeKeychain: ClaudeCredentialStore {
    static let service = "Claude Code-credentials"

    func read() throws -> ClaudeOAuthCredential {
        let find: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecReturnAttributes: true,
            kSecReturnPersistentRef: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var found: CFTypeRef?
        let findStatus = SecItemCopyMatching(find as CFDictionary, &found)
        guard findStatus == errSecSuccess, let items = found as? [[String: Any]] else {
            throw Self.error(for: findStatus)
        }
        let newest = items.max { Self.modified($0) < Self.modified($1) }
        guard let reference = newest?[kSecValuePersistentRef as String] as? Data else {
            throw ClaudeCredentialError.notFound
        }

        let fetch: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecValuePersistentRef: reference,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(fetch as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { throw Self.error(for: status) }
        return try ClaudeOAuthCredential.decode(data)
    }

    private static func modified(_ attributes: [String: Any]) -> Date {
        attributes[kSecAttrModificationDate as String] as? Date ?? .distantPast
    }

    static func error(for status: OSStatus) -> ClaudeCredentialError {
        switch status {
        case errSecItemNotFound:
            return .notFound
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            return .denied
        // In dark wake, and an authorization that needed a dialogue it could not show.
        case -25320, -60008:
            return .notNow
        default:
            return .unreadable
        }
    }
}
