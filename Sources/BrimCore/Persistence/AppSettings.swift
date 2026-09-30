import Foundation

/// Which screen edge the notch is welded to.
public enum NotchEdge: String, Codable, CaseIterable, Identifiable, Sendable {
    case right, left, top, bottom

    public var id: String { rawValue }
    /// True when the stack runs down the screen rather than across it.
    public var isVertical: Bool { self == .right || self == .left }

    public var title: String {
        switch self {
        case .right:  return "Right"
        case .left:   return "Left"
        case .top:    return "Top"
        case .bottom: return "Bottom"
        }
    }
}

public enum NotchSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case small, medium, large

    public var id: String { rawValue }
    public var scale: Double {
        switch self {
        case .small:  return 0.8
        case .medium: return 1
        case .large:  return 1.25
        }
    }
    public var title: String { rawValue.capitalized }
}

public enum NotchVisibility: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Stays open with every reading visible.
    case alwaysShow
    /// A small pill at the edge that opens when the pointer reaches it.
    case onHover
    /// Nothing on screen; readings stay in the menu bar menu.
    case hidden

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .alwaysShow: return "Always show"
        case .onHover:    return "Show on hover"
        case .hidden:     return "Hide"
        }
    }
}

public enum AppPresence: String, Codable, CaseIterable, Identifiable, Sendable {
    case dock, menuBar, neither

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .dock:    return "Dock"
        case .menuBar: return "Menu bar"
        case .neither: return "Neither"
        }
    }
}

public enum DisplayScope: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The display with the menu bar.
    case main
    /// One notch on every display.
    case all
    /// One chosen display, remembered by its hardware UUID.
    case specific

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .main:     return "Main display"
        case .all:      return "All displays"
        case .specific: return "Chosen display"
        }
    }
}

public enum RingClickAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case refresh, openUsagePage

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .refresh:       return "Refresh that provider"
        case .openUsagePage: return "Open its usage page"
        }
    }
}

/// The ring's "plenty of room" colour. Warning colours never change: their job
/// is to interrupt, and a customisable warning can be tuned into invisibility.
public enum AccentChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case green = "00ff88"
    case system
    case pink = "ff33e1"
    case red = "eb4236"
    case orange = "eb8436"
    case yellow = "ffd400"
    case teal = "00e5cc"
    case blue = "36a8eb"
    case indigo = "6c5ce7"
    case purple = "b026ff"
    case offWhite = "f7f6f5"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .green:    return "Green"
        case .system:   return "Device accent"
        case .pink:     return "Pink"
        case .red:      return "Red"
        case .orange:   return "Orange"
        case .yellow:   return "Yellow"
        case .teal:     return "Teal"
        case .blue:     return "Blue"
        case .indigo:   return "Indigo"
        case .purple:   return "Purple"
        case .offWhite: return "Off-white"
        }
    }

    /// Nil for the device accent, which the UI resolves from the system.
    public var hex: UInt32? {
        self == .system ? nil : UInt32(rawValue, radix: 16)
    }
}

public struct ClaudeSettings: Codable, Equatable, Sendable {
    /// Read the usage figures Claude Code caches in ~/.claude.json. Local, on.
    public var readUsageCache: Bool = true
    /// Ask the installed `claude` binary for official figures. Network, off.
    public var useUsageCommand: Bool = false
    /// Seconds between `/usage` runs. Never below five minutes.
    public var usageCommandInterval: Double = 600
    /// While Claude Code isn't reporting, ask Anthropic's usage endpoint with
    /// Claude Code's sign-in, read from the keychain on a click. Network, off.
    public var refreshWhileClosed: Bool = false
    /// Seconds between those requests. Never below five minutes.
    public var refreshWhileClosedInterval: Double = 600
    /// A budget for the rolling five-hour window, in weighted tokens.
    public var sessionBudget: Double?
    /// A budget for the rolling week, in weighted tokens.
    public var weeklyBudget: Double?
    /// Size the budget from Anthropic's own figures: a logged limit hit, or a
    /// reported percentage. The key predates the second source.
    public var calibrateFromLimitHits: Bool = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClaudeSettings()
        readUsageCache = try c.decodeIfPresent(Bool.self, forKey: .readUsageCache) ?? d.readUsageCache
        useUsageCommand = try c.decodeIfPresent(Bool.self, forKey: .useUsageCommand) ?? d.useUsageCommand
        usageCommandInterval = try c.decodeIfPresent(Double.self, forKey: .usageCommandInterval) ?? d.usageCommandInterval
        refreshWhileClosed = try c.decodeIfPresent(Bool.self, forKey: .refreshWhileClosed) ?? d.refreshWhileClosed
        refreshWhileClosedInterval = try c.decodeIfPresent(Double.self, forKey: .refreshWhileClosedInterval)
            ?? d.refreshWhileClosedInterval
        sessionBudget = try c.decodeIfPresent(Double.self, forKey: .sessionBudget)
        weeklyBudget = try c.decodeIfPresent(Double.self, forKey: .weeklyBudget)
        calibrateFromLimitHits = try c.decodeIfPresent(Bool.self, forKey: .calibrateFromLimitHits) ?? d.calibrateFromLimitHits
    }
}

public struct LocalRuntimeSettings: Codable, Equatable, Sendable {
    public var port: Int
    /// Read request counts and timings from the runtime's own log files.
    public var readLogs: Bool = true

    public init(port: Int, readLogs: Bool = true) {
        self.port = port
        self.readLogs = readLogs
    }
}

/// Everything Brim remembers between launches. Only preferences and the
/// numbers you typed in — never credentials, never provider responses.
public struct AppSettings: Codable, Equatable, Sendable {
    // Notch
    public var edge: NotchEdge = .right
    /// Distance slid along each edge from its centre, in points.
    public var alongOffsets: [String: Double] = [:]
    public var size: NotchSize = .medium
    public var visibility: NotchVisibility = .onHover
    public var foldsForFullScreen: Bool = true
    public var accent: AccentChoice = .green
    public var resetTimeFormat: ResetTimeFormat = .automatic
    public var displayScope: DisplayScope = .main
    public var chosenDisplayID: String?
    public var ringClickAction: RingClickAction = .refresh

    // App
    public var appPresence: AppPresence = .menuBar
    public var menuBarShowsReadings: Bool = false
    public var refreshInterval: Double = 120
    public var demoMode: Bool = false

    // Alerts and sessions
    public var thresholdAlerts: Bool = true
    public var mutedProviders: [String] = []
    public var peekOnFinish: Bool = true
    public var peekOnWaiting: Bool = true
    public var peekDuration: Double = 5
    public var sessionNotifications: Bool = false
    public var clickActivatesSessionApp: Bool = true
    public var showSessionTitles: Bool = false

    // Providers
    public var providerOrder: [String] = []
    public var enabledProviders: [String: Bool] = [:]
    public var claude = ClaudeSettings()
    public var ollama = LocalRuntimeSettings(port: 11434)
    public var lmStudio = LocalRuntimeSettings(port: 1234)
    public var manualProviders: [ManualProviderConfig] = []

    public init() {}

    public static let refreshChoices: [Double] = [60, 120, 300, 600, 900]

    public func alongOffset(for edge: NotchEdge) -> Double {
        alongOffsets[edge.rawValue] ?? 0
    }

    public mutating func setAlongOffset(_ value: Double, for edge: NotchEdge) {
        alongOffsets[edge.rawValue] = value
    }

    /// Whether a provider instance is switched on, falling back to its kind's
    /// default. Networked adapters default to off.
    public func isEnabled(_ id: String, kind: ProviderKind) -> Bool {
        enabledProviders[id] ?? (kind == .manual ? true : kind.enabledByDefault)
    }

    public func isMuted(_ id: String) -> Bool { mutedProviders.contains(id) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            // A value that no longer decodes (a removed enum case, say) falls
            // back to the default instead of discarding every other setting.
            (try? c.decodeIfPresent(T.self, forKey: key)).flatMap { $0 } ?? fallback
        }
        edge = value(.edge, d.edge)
        alongOffsets = value(.alongOffsets, d.alongOffsets)
        size = value(.size, d.size)
        visibility = value(.visibility, d.visibility)
        foldsForFullScreen = value(.foldsForFullScreen, d.foldsForFullScreen)
        accent = value(.accent, d.accent)
        resetTimeFormat = value(.resetTimeFormat, d.resetTimeFormat)
        displayScope = value(.displayScope, d.displayScope)
        chosenDisplayID = value(.chosenDisplayID, d.chosenDisplayID)
        ringClickAction = value(.ringClickAction, d.ringClickAction)
        appPresence = value(.appPresence, d.appPresence)
        menuBarShowsReadings = value(.menuBarShowsReadings, d.menuBarShowsReadings)
        refreshInterval = value(.refreshInterval, d.refreshInterval)
        demoMode = value(.demoMode, d.demoMode)
        thresholdAlerts = value(.thresholdAlerts, d.thresholdAlerts)
        mutedProviders = value(.mutedProviders, d.mutedProviders)
        peekOnFinish = value(.peekOnFinish, d.peekOnFinish)
        peekOnWaiting = value(.peekOnWaiting, d.peekOnWaiting)
        peekDuration = value(.peekDuration, d.peekDuration)
        sessionNotifications = value(.sessionNotifications, d.sessionNotifications)
        clickActivatesSessionApp = value(.clickActivatesSessionApp, d.clickActivatesSessionApp)
        showSessionTitles = value(.showSessionTitles, d.showSessionTitles)
        providerOrder = value(.providerOrder, d.providerOrder)
        enabledProviders = value(.enabledProviders, d.enabledProviders)
        claude = value(.claude, d.claude)
        ollama = value(.ollama, d.ollama)
        lmStudio = value(.lmStudio, d.lmStudio)
        manualProviders = value(.manualProviders, d.manualProviders)
    }
}
