import Foundation

/// Where "Refresh while Claude Code is closed" stands, for Settings.
public enum ClaudeFallbackState: Equatable, Sendable {
    case off
    /// On, but holding no sign-in: someone has to click "Allow access…".
    case needsApproval
    case denied
    case notSignedIn
    /// The sign-in Brim was given has aged out, or Anthropic turned it away
    /// because Claude Code has renewed it since.
    case expired
    /// Claude Code is reporting by itself, so there is nothing to ask.
    case standingBy
    case checked(Date)
    case retrying(until: Date, reason: String)
    case failed(String)

    public var message: String {
        switch self {
        case .off:
            return "Off."
        case .needsApproval:
            return "Waiting for your OK to read Claude Code's sign-in."
        case .denied:
            return "Keychain access was declined, so nothing is being asked."
        case .notSignedIn:
            return "Claude Code isn't signed in on this Mac."
        case .expired:
            return "The sign-in Brim was given has expired or been replaced. Allow access again after Claude Code has renewed it (it does when you next use it)."
        case .standingBy:
            return "Claude Code is reporting by itself, so Brim isn't asking."
        case .checked(let at):
            return "Last asked Anthropic at \(at.formatted(date: .omitted, time: .shortened))."
        case .retrying(let until, let reason):
            return "\(reason) Trying again at \(until.formatted(date: .omitted, time: .shortened))."
        case .failed(let reason):
            return reason
        }
    }

    /// Whether the "Allow access…" button has anything to do.
    public var needsAccess: Bool {
        switch self {
        case .needsApproval, .denied, .notSignedIn, .expired, .failed: return true
        case .off, .standingBy, .checked, .retrying: return false
        }
    }
}

/// What Settings shows about where Claude's figures are coming from.
public struct ClaudeSourceStatus: Equatable, Sendable {
    /// When Claude Code's status line last handed figures over.
    public var statuslineReportedAt: Date?
    /// When Claude Code last cached Anthropic's figures in ~/.claude.json.
    public var cacheFetchedAt: Date?
    public var fallback: ClaudeFallbackState = .off

    public init() {}
}

/// "Refresh while Claude Code is closed": Anthropic's usage endpoint, asked with
/// Claude Code's own sign-in, only while nothing on this Mac is reporting.
///
/// The keychain is read only when someone clicks (switching this on, or "Allow
/// access…"), never on a timer, so macOS only ever asks in answer to a click.
/// The sign-in is held in memory, used until it expires or Anthropic turns it
/// away, and dropped when this is switched off. Brim never renews it: that
/// would mean writing a credential that belongs to Claude Code.
final class ClaudeUsageFallback {
    /// Local figures younger than this mean Claude Code is running and reporting.
    static let staleAfter: TimeInterval = 10 * 60
    static let minimumInterval: TimeInterval = 5 * 60
    static let maximumBackoff: TimeInterval = 60 * 60

    private let credentials: ClaudeCredentialStore
    private let endpoint: ClaudeUsageEndpoint
    private var credential: ClaudeOAuthCredential?
    private(set) var reading: OfficialReading?
    private(set) var state: ClaudeFallbackState = .off
    private var lastAttempt: Date?
    private var retryAt: Date?
    private var failures = 0

    init(credentials: ClaudeCredentialStore, endpoint: ClaudeUsageEndpoint) {
        self.credentials = credentials
        self.endpoint = endpoint
    }

    /// Someone clicked: read the keychain, letting macOS ask them.
    func requestAccess(now: Date) {
        lastAttempt = nil
        retryAt = nil
        failures = 0
        do {
            let fresh = try credentials.read()
            guard !fresh.isExpired(at: now) else {
                credential = nil
                state = .expired
                return
            }
            credential = fresh
            state = .standingBy
        } catch let error as ClaudeCredentialError {
            credential = nil
            switch error {
            case .notFound, .signedOut: state = .notSignedIn
            case .denied: state = .denied
            case .notNow: state = .failed("macOS couldn't ask just then. Try again in a moment.")
            case .unreadable: state = .failed("Claude Code's sign-in isn't in a shape Brim recognises.")
            }
        } catch {
            credential = nil
            state = .failed("Couldn't read Claude Code's sign-in.")
        }
    }

    /// Switched off: drop the sign-in and everything learned with it.
    func forget() {
        credential = nil
        reading = nil
        state = .off
        lastAttempt = nil
        retryAt = nil
        failures = 0
    }

    /// Runs on each refresh while switched on. `freshestLocal` is when any
    /// source on this Mac last reported Anthropic's figures.
    func poll(now: Date, freshestLocal: Date?, interval: TimeInterval) async {
        guard let credential else {
            if state == .off || state == .standingBy { state = .needsApproval }
            return
        }
        guard !credential.isExpired(at: now) else {
            self.credential = nil
            state = .expired
            return
        }
        if let freshestLocal, now.timeIntervalSince(freshestLocal) < Self.staleAfter {
            if case .checked = state { return }
            state = .standingBy
            return
        }
        if let retryAt, now < retryAt { return }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < max(interval, Self.minimumInterval) { return }
        lastAttempt = now

        let response: EndpointResponse
        do {
            response = try await endpoint.fetchUsage(accessToken: credential.accessToken)
        } catch {
            backOff(now: now, suggested: nil, reason: "Couldn't reach Anthropic.")
            return
        }
        switch response.status {
        case 200:
            guard let windows = ClaudeUsageCache.windows(fromUtilization: response.body) else {
                backOff(now: now, suggested: nil, reason: "Anthropic's answer wasn't in the expected shape.")
                return
            }
            reading = OfficialReading(at: now, windows: windows, plan: credential.plan?.capitalized, origin: .endpoint)
            failures = 0
            retryAt = nil
            state = .checked(now)
        case 401, 403:
            // Claude Code has renewed its sign-in; this copy is dead. Asking the
            // keychain again is the person's call, not a timer's.
            self.credential = nil
            state = .expired
        case 429:
            backOff(now: now, suggested: response.retryAfter, reason: "Anthropic asked Brim to slow down.")
        default:
            backOff(now: now, suggested: response.retryAfter, reason: "Anthropic answered \(response.status).")
        }
    }

    private func backOff(now: Date, suggested: TimeInterval?, reason: String) {
        failures += 1
        let doubling = Self.minimumInterval * pow(2, Double(min(failures - 1, 6)))
        let delay = min(max(suggested ?? doubling, Self.minimumInterval), Self.maximumBackoff)
        let until = now.addingTimeInterval(delay)
        retryAt = until
        state = .retrying(until: until, reason: reason)
    }
}
