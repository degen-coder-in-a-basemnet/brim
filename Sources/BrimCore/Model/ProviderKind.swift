import Foundation

/// A mark drawn in the middle of a ring. Brim draws its own marks rather than
/// shipping vendor logos.
public enum ProviderGlyph: Codable, Equatable, Hashable, Sendable {
    /// A twelve-ray starburst, used for Claude Code.
    case asterisk
    /// A prompt chevron and cursor, used for Codex.
    case prompt
    /// An SF Symbol, by name.
    case symbol(String)
    /// One or two letters, for providers you add yourself.
    case monogram(String)
}

/// What an adapter touches on the network, stated up front so Settings and the
/// privacy document can show it before anything is switched on.
public enum NetworkUse: Equatable, Sendable {
    /// Reads files on this Mac only.
    case none
    /// Talks to a server on this Mac, over the loopback interface only.
    case loopback(defaultPort: Int, paths: [String])
    /// Runs an installed command-line tool that makes its own requests to the
    /// vendor. Brim never sees its credentials.
    case viaCLI(binary: String, hosts: [String])

    public var isNetworked: Bool { self != .none }
}

/// Every adapter Brim ships, with the facts about it that do not depend on
/// configuration.
public enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case claudeCode
    case codex
    case manual
    case ollama
    case lmStudio
    case demo

    public var displayName: String {
        switch self {
        case .claudeCode:     return "Claude Code"
        case .codex:          return "Codex"
        case .manual:         return "Manual"
        case .ollama:         return "Ollama"
        case .lmStudio:       return "LM Studio"
        case .demo:           return "Demo"
        }
    }

    public var defaultGlyph: ProviderGlyph {
        switch self {
        case .claudeCode: return .asterisk
        case .codex:    return .prompt
        case .manual:   return .monogram("M")
        case .ollama:   return .symbol("cube.transparent")
        case .lmStudio: return .symbol("square.stack.3d.up")
        case .demo:     return .symbol("sparkles")
        }
    }

    public var fidelity: Fidelity {
        switch self {
        case .claudeCode:     return .derived
        case .codex:          return .official
        case .manual:         return .manual
        case .ollama, .lmStudio: return .local
        case .demo:           return .derived
        }
    }

    public var network: NetworkUse {
        switch self {
        case .claudeCode, .codex, .manual, .demo:
            return .none
        case .ollama:
            return .loopback(defaultPort: 11434, paths: ["/api/ps", "/api/version"])
        case .lmStudio:
            return .loopback(defaultPort: 1234, paths: ["/api/v0/models"])
        }
    }

    /// Anything networked starts switched off and needs an explicit opt-in.
    public var enabledByDefault: Bool {
        switch self {
        case .claudeCode, .codex: return true
        default: return false
        }
    }

    /// Exactly what the adapter reads, in plain words.
    public var dataAccess: [String] {
        switch self {
        case .claudeCode:
            return [
                "Reads ~/.claude/projects/**/*.jsonl for token counts, timestamps and rate-limit records. Message text is never kept.",
                "Reads ~/.claude/sessions/*.json for each session's status, folder and process id.",
                "Reads the cachedUsageUtilization entry of ~/.claude.json: Anthropic's percentages as Claude Code last fetched them. Nothing else in that file is decoded.",
                "If your status-line command writes it, reads ~/Library/Application Support/Brim/claude-statusline.json: the percentages and reset times Claude Code last handed the status line.",
                "Only with “Refresh while Claude Code is closed” on, and only when you click: reads Claude Code's sign-in from the keychain item “Claude Code-credentials” and sends it to https://api.anthropic.com/api/oauth/usage alone.",
            ]
        case .codex:
            return [
                "Reads ~/.codex/sessions/**/rollout-*.jsonl for the rate-limit figures and task events Codex records. Messages are never kept.",
            ]
        case .manual:
            return ["Uses only the limits you enter in Settings."]
        case .ollama:
            return [
                "Asks http://127.0.0.1 (default port 11434) for /api/ps and /api/version: loaded models, sizes, unload times.",
                "Reads request counts and timings from ~/.ollama/logs/server.log. Never a prompt or a reply.",
            ]
        case .lmStudio:
            return [
                "Asks http://127.0.0.1 (default port 1234) for /api/v0/models: which models are loaded.",
                "Reads counts and timings from ~/.lmstudio/server-logs. Never a prompt or a reply.",
            ]
        case .demo:
            return ["Fixed sample data generated in the app. Reads nothing."]
        }
    }

    public var supportsSessions: Bool {
        switch self {
        case .claudeCode, .codex, .demo: return true
        default: return false
        }
    }

    /// Opened in the browser only when you choose "Open usage page".
    public var usagePageURL: URL? {
        switch self {
        case .claudeCode: return URL(string: "https://claude.ai/settings/usage")
        case .codex: return URL(string: "https://chatgpt.com/codex/settings/usage")
        default: return nil
        }
    }
}

/// Services Brim deliberately does not read, with the reason, so Settings can
/// say why they are missing instead of leaving it to be guessed.
public struct UnsupportedProvider: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let reason: String

    public static let all: [UnsupportedProvider] = [
        .init(id: "cursor", name: "Cursor",
              reason: "Usage needs the editor's session token from its local database. Reading it would be credential access; add a Manual provider instead."),
        .init(id: "copilot", name: "GitHub Copilot",
              reason: "Quota is only exposed by an authenticated GitHub endpoint. Needs authentication."),
        .init(id: "gemini", name: "Gemini CLI",
              reason: "Keeps no local record of quota. Needs authentication against Google's API."),
        .init(id: "chatgpt", name: "ChatGPT (web)",
              reason: "Only the signed-in web session knows the limits; Brim does not read browser cookies."),
        .init(id: "claude-desktop", name: "Claude Desktop cache",
              reason: "Official figures sit in Claude Desktop's private HTTP cache. Not read: it is another app's internal storage."),
        .init(id: "api-keys", name: "Vendor API keys",
              reason: "Brim never asks for API keys. Use a Manual provider for API budgets."),
    ]
}
