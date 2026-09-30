import Foundation

/// One adapter. The store asks it for a snapshot on a timer and, if it can see
/// sessions, for those on a faster one. How it gets them is its own business:
/// the UI only ever sees what comes back.
///
/// An adapter never throws. Every failure becomes a `ProviderStatus`, so the
/// worst a broken source can do is show "Unavailable" on its own ring.
public protocol UsageProvider: AnyObject {
    /// The instance id: stable across launches, unique among providers.
    var id: String { get }
    var kind: ProviderKind { get }
    var displayName: String { get }

    func fetchSnapshot(now: Date) async -> ProviderSnapshot
    /// Live sessions, when the provider can see them. Called often: keep it cheap.
    func sessions(now: Date) async -> [AgentSession]
}

public extension UsageProvider {
    func sessions(now: Date) async -> [AgentSession] { [] }

    /// A snapshot carrying only a status, for the early returns every adapter has.
    func statusSnapshot(_ status: ProviderStatus, glyph: ProviderGlyph? = nil,
                        fidelity: Fidelity? = nil, now: Date) -> ProviderSnapshot {
        ProviderSnapshot(id: id, kind: kind, displayName: displayName,
                         glyph: glyph ?? kind.defaultGlyph, fidelity: fidelity ?? kind.fidelity,
                         capturedAt: now, status: status)
    }
}

/// Where the adapters look. Injected so tests can point everything at a
/// temporary directory instead of the real home folder.
public struct ProviderEnvironment: Sendable {
    public var home: URL
    public var applicationSupport: URL

    public init(home: URL, applicationSupport: URL) {
        self.home = home
        self.applicationSupport = applicationSupport
    }

    public static var current: ProviderEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support")
        return ProviderEnvironment(home: home, applicationSupport: support.appendingPathComponent("Brim"))
    }

    public var claudeDirectory: URL { home.appendingPathComponent(".claude") }
    /// Claude Code's own settings file. Only its cached usage figures are read.
    public var claudeConfigFile: URL { home.appendingPathComponent(".claude.json") }
    public var codexDirectory: URL { home.appendingPathComponent(".codex") }
    public var ollamaLogs: URL { home.appendingPathComponent(".ollama/logs") }
    public var lmStudioServerLogs: URL { home.appendingPathComponent(".lmstudio/server-logs") }
}
