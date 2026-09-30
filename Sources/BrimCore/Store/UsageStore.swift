import Combine
import Foundation

/// A provider instance Settings can list, whether or not it is switched on.
public struct ProviderListing: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: ProviderKind
    public let name: String
    public let glyph: ProviderGlyph
}

/// The one source of truth the UI reads.
///
/// It polls every enabled adapter on the refresh interval, and the ones that
/// can see sessions every two seconds. It keeps the last good reading across
/// launches, dims anything too old, and turns every failure into a visible
/// status. The UI never learns how any of it was fetched.
@MainActor
public final class UsageStore: ObservableObject {
    /// Enabled providers, in the user's order.
    @Published public private(set) var snapshots: [ProviderSnapshot] = []
    /// Live sessions per provider id.
    @Published public private(set) var activity: [String: ActivitySummary] = [:]
    /// Providers with a fetch in flight that the user asked for.
    @Published public private(set) var refreshing: Set<String> = []
    /// Where Claude's figures are coming from, for Settings.
    @Published public private(set) var claudeSources = ClaudeSourceStatus()

    public let thresholdAlerts = PassthroughSubject<ThresholdAlert, Never>()
    public let sessionEvents = PassthroughSubject<SessionEvent, Never>()

    public let settingsStore: SettingsStore
    private let archive: ReadingArchiveStore
    private let environment: ProviderEnvironment
    private let files: LocalFileAccess
    private let client = LoopbackHTTPClient()

    private var providers: [String: any UsageProvider] = [:]
    private var latest: [String: ProviderSnapshot] = [:]
    private var sessions: [String: [AgentSession]] = [:]
    private var inFlight: Set<String> = []
    private var sessionsInFlight = false
    private let thresholds = ThresholdTracker()
    private let transitions = SessionTransitionDetector()
    private var refreshTimer: Timer?
    private var sessionTimer: Timer?
    private var clockTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var appliedSettings: AppSettings?
    /// Fixed clock for snapshot rendering; nil means real time.
    private let fixedNow: Date?

    public init(settingsStore: SettingsStore, archive: ReadingArchiveStore,
                environment: ProviderEnvironment = .current, fixedNow: Date? = nil) {
        self.settingsStore = settingsStore
        self.archive = archive
        self.environment = environment
        self.files = LocalFileAccess.standard(environment)
        self.fixedNow = fixedNow
    }

    public var now: Date { fixedNow ?? Date() }
    public var settings: AppSettings { settingsStore.settings }
    /// The settings last applied. `@Published` announces a change before it
    /// stores it, so while a change is being applied `settingsStore.settings`
    /// still holds the old value; everything internal reads this instead.
    private var current: AppSettings { appliedSettings ?? settingsStore.settings }

    // MARK: - Lifecycle

    public func start() {
        apply(settings: settingsStore.settings)
        settingsStore.$settings
            .dropFirst()
            .sink { [weak self] settings in
                MainActor.assumeIsolated { self?.apply(settings: settings) }
            }
            .store(in: &cancellables)
        scheduleTimers()
        refreshAll()
        pollSessions()
    }

    public func stop() {
        refreshTimer?.invalidate()
        sessionTimer?.invalidate()
        clockTimer?.invalidate()
        archive.saveNow()
        settingsStore.saveNow()
    }

    /// Loads every provider's figures once, synchronously enough for a
    /// snapshot render: used by the offline renderer and the tests.
    public func loadOnce() async {
        apply(settings: settingsStore.settings)
        await withTaskGroup(of: (String, ProviderSnapshot).self) { group in
            let now = self.now
            for (id, provider) in providers {
                group.addTask { (id, await provider.fetchSnapshot(now: now)) }
            }
            for await (id, snapshot) in group { latest[id] = snapshot }
        }
        for (id, provider) in providers where provider.kind.supportsSessions {
            sessions[id] = await provider.sessions(now: now)
        }
        publish()
        publishActivity()
    }

    private func scheduleTimers() {
        refreshTimer?.invalidate()
        let interval = max(30, current.refreshInterval)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAll() }
        }
        refreshTimer?.tolerance = interval * 0.1
        if sessionTimer == nil {
            sessionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollSessions() }
            }
            sessionTimer?.tolerance = 0.5
        }
        if clockTimer == nil {
            clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    // MARK: - Providers

    /// Every provider instance Settings should list.
    public var listings: [ProviderListing] { listings(for: current) }

    func listings(for settings: AppSettings) -> [ProviderListing] {
        if settings.demoMode {
            return DemoData.ids.map { id in
                let sample = DemoData.snapshot(id: id, now: now)
                return ProviderListing(id: id, kind: .demo, name: sample.displayName, glyph: sample.glyph)
            }
        }
        var result: [ProviderListing] = [
            ProviderListing(id: "claudeCode", kind: .claudeCode, name: "Claude Code", glyph: .asterisk),
            ProviderListing(id: "codex", kind: .codex, name: "Codex", glyph: .prompt),
            ProviderListing(id: "ollama", kind: .ollama, name: "Ollama", glyph: ProviderKind.ollama.defaultGlyph),
            ProviderListing(id: "lmStudio", kind: .lmStudio, name: "LM Studio", glyph: ProviderKind.lmStudio.defaultGlyph),
        ]
        result += settings.manualProviders.map {
            ProviderListing(id: $0.id, kind: .manual, name: $0.name, glyph: .monogram($0.monogram))
        }
        let ordered = ProviderOrdering.apply(order: settings.providerOrder, to: result.map(\.id))
        return ordered.compactMap { id in result.first { $0.id == id } }
    }

    private func apply(settings: AppSettings) {
        let previous = appliedSettings
        appliedSettings = settings

        if previous?.demoMode != settings.demoMode {
            providers.removeAll()
            latest.removeAll()
            sessions.removeAll()
            transitions.reset()
        }

        var wanted: [String: ProviderKind] = [:]
        if settings.demoMode {
            for id in DemoData.ids where settings.enabledProviders[id] ?? true { wanted[id] = .demo }
        } else {
            for listing in listings(for: settings) where settings.isEnabled(listing.id, kind: listing.kind) {
                wanted[listing.id] = listing.kind
            }
        }

        // Switched off: stop polling, forget its readings and sessions.
        for id in providers.keys where wanted[id] == nil {
            providers.removeValue(forKey: id)
            latest.removeValue(forKey: id)
            sessions.removeValue(forKey: id)
            thresholds.forget(id)
            archive.forget(id)
        }

        // Switched on, or new: build it, and show its last reading, dimmed.
        var added: [String] = []
        for (id, kind) in wanted where providers[id] == nil {
            guard let provider = makeProvider(id: id, kind: kind, settings: settings) else { continue }
            providers[id] = provider
            added.append(id)
            if latest[id] == nil, let remembered = archive.archive.readings[id] {
                latest[id] = remembered.staleSnapshot
            }
        }

        // Settings the adapters care about.
        for (id, provider) in providers {
            switch provider {
            case let claude as ClaudeCodeProvider:
                let claudeSettings = settings.claude
                let titles = settings.showSessionTitles
                // Switching the fallback on is itself the click that may read the
                // keychain. At launch nothing is read: it waits for "Allow access…".
                let switchedOn = previous.map { !$0.claude.refreshWhileClosed } == true && claudeSettings.refreshWhileClosed
                let now = self.now
                Task {
                    await claude.update(settings: claudeSettings, showSessionTitles: titles)
                    if switchedOn {
                        await claude.requestKeychainAccess(now: now)
                        self.refresh(id, userInitiated: false)
                    }
                    self.claudeSources = await claude.sourceStatus()
                }
            case let ollama as OllamaProvider:
                let runtime = settings.ollama
                Task { await ollama.update(settings: runtime) }
            case let lmStudio as LMStudioProvider:
                let runtime = settings.lmStudio
                Task { await lmStudio.update(settings: runtime) }
            case let manual as ManualProvider:
                if let config = settings.manualProviders.first(where: { $0.id == id }) {
                    Task {
                        await manual.update(config: config)
                        self.refresh(id, userInitiated: false)
                    }
                }
            default:
                break
            }
        }

        if previous?.refreshInterval != settings.refreshInterval { scheduleTimers() }
        publish()
        for id in added { refresh(id, userInitiated: false) }
        if previous != nil, previous?.claude != settings.claude, providers["claudeCode"] != nil {
            refresh("claudeCode", userInitiated: false)
        }
    }

    private func makeProvider(id: String, kind: ProviderKind, settings: AppSettings) -> (any UsageProvider)? {
        switch kind {
        case .demo:
            return DemoProvider(id: id)
        case .claudeCode:
            let archive = self.archive
            return ClaudeCodeProvider(
                environment: environment, files: files, settings: settings.claude,
                showSessionTitles: settings.showSessionTitles,
                calibration: archive.archive.claudeCalibration,
                persistCalibration: { calibration in
                    Task { @MainActor in archive.setCalibration(calibration) }
                })
        case .codex:
            return CodexProvider(environment: environment, files: files)
        case .ollama:
            return OllamaProvider(environment: environment, files: files, settings: settings.ollama, client: client)
        case .lmStudio:
            return LMStudioProvider(environment: environment, files: files, settings: settings.lmStudio, client: client)
        case .manual:
            return settings.manualProviders.first { $0.id == id }.map { ManualProvider(config: $0) }
        }
    }

    // MARK: - Refreshing

    public func refreshAll() {
        rollOverManualProviders()
        for id in providers.keys { refresh(id, userInitiated: false) }
    }

    /// Refetches one provider. A click on its ring lands here.
    public func refresh(_ id: String, userInitiated: Bool = true) {
        guard let provider = providers[id], !inFlight.contains(id) else { return }
        inFlight.insert(id)
        if userInitiated { refreshing.insert(id) }
        let now = self.now
        Task {
            let snapshot = await provider.fetchSnapshot(now: now)
            if let claude = provider as? ClaudeCodeProvider { self.claudeSources = await claude.sourceStatus() }
            self.inFlight.remove(id)
            self.refreshing.remove(id)
            // Switched off while in flight: drop the answer.
            guard self.providers[id] != nil else { return }
            self.receive(snapshot)
        }
    }

    private func receive(_ snapshot: ProviderSnapshot) {
        if snapshot.status.isProblem, let previous = latest[snapshot.id], !previous.windows.isEmpty {
            // Keep the last numbers on screen, dimmed, with the problem said.
            var kept = previous.markedStale(since: previous.capturedAt ?? now)
            kept.source = [previous.source, snapshot.status.message].compactMap { $0 }.joined(separator: " · ")
            latest[snapshot.id] = kept
        } else {
            latest[snapshot.id] = snapshot
            archive.remember(snapshot)
        }
        publish()
    }

    private func tick() {
        rollOverManualProviders()
        publish()
    }

    private func rollOverManualProviders() {
        let now = self.now
        var changed = false
        var configs = current.manualProviders
        for index in configs.indices {
            if let rolled = configs[index].rolledOver(now: now) {
                configs[index] = rolled
                changed = true
            }
        }
        if changed { settingsStore.update { $0.manualProviders = configs } }
    }

    private func publish() {
        let now = self.now
        let settings = current
        let ordered = ProviderOrdering.apply(order: settings.providerOrder, to: Array(providers.keys).sorted())
        let next = ordered.compactMap { id -> ProviderSnapshot? in
            guard let snapshot = latest[id] else { return nil }
            let maxAge = Staleness.maxAge(for: snapshot.kind, refreshInterval: settings.refreshInterval)
            return Staleness.evaluate(snapshot, now: now, maxAge: maxAge)
        }
        if next != snapshots { snapshots = next }

        guard settings.thresholdAlerts, !settings.demoMode else { return }
        let muted = Set(settings.mutedProviders)
        for alert in thresholds.observe(next, isMuted: { muted.contains($0) }) {
            thresholdAlerts.send(alert)
        }
    }

    // MARK: - Sessions

    private func pollSessions() {
        guard !sessionsInFlight else { return }
        let watched = providers.filter { $0.value.kind.supportsSessions }
        guard !watched.isEmpty else {
            if !activity.isEmpty { activity = [:] }
            return
        }
        sessionsInFlight = true
        let now = self.now
        Task {
            var found: [String: [AgentSession]] = [:]
            for (id, provider) in watched {
                found[id] = await provider.sessions(now: now)
            }
            self.sessionsInFlight = false
            for (id, list) in found where self.providers[id] != nil { self.sessions[id] = list }
            self.publishActivity()
        }
    }

    private func publishActivity() {
        var next: [String: ActivitySummary] = [:]
        for (id, list) in sessions where !list.isEmpty && providers[id] != nil {
            next[id] = ActivitySummary(sessions: list)
        }
        if next != activity { activity = next }

        let names = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0.displayName) })
        let events = transitions.observe(sessions.values.flatMap { $0 }) { names[$0] ?? "Agent" }
        for event in events { sessionEvents.send(event) }
    }

    // MARK: - Actions from the UI

    public func setEnabled(_ enabled: Bool, id: String) {
        settingsStore.update { settings in
            settings.enabledProviders[id] = enabled
            if enabled {
                settings.providerOrder = ProviderOrdering.enabling(id, in: settings.providerOrder.isEmpty
                    ? self.listings.map(\.id) : settings.providerOrder)
            }
        }
    }

    public func moveProviders(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let current = listings.map(\.id)
        settingsStore.update { $0.providerOrder = ProviderOrdering.move(current, fromOffsets: offsets, toOffset: destination) }
    }

    /// Adds `amount` to a manual window's count, from the ring's menu.
    public func adjustManual(providerID: String, windowID: String, by amount: Double) {
        settingsStore.update { settings in
            guard let p = settings.manualProviders.firstIndex(where: { $0.id == providerID }),
                  let w = settings.manualProviders[p].windows.firstIndex(where: { $0.id == windowID })
            else { return }
            let current = settings.manualProviders[p].windows[w].used
            settings.manualProviders[p].windows[w].used = max(0, current + amount)
        }
    }

    public func resetManual(providerID: String) {
        let now = self.now
        settingsStore.update { settings in
            guard let p = settings.manualProviders.firstIndex(where: { $0.id == providerID }) else { return }
            for w in settings.manualProviders[p].windows.indices {
                settings.manualProviders[p].windows[w].used = 0
                settings.manualProviders[p].windows[w].lastReset = now
            }
        }
    }

    public func snapshot(for id: String) -> ProviderSnapshot? {
        snapshots.first { $0.id == id }
    }

    /// The Claude budget last measured from a logged limit hit.
    public var claudeCalibration: ClaudeCalibration? { archive.archive.claudeCalibration }

    /// "Allow access…": read Claude Code's sign-in from the keychain now, with
    /// macOS asking first. Nothing else in Brim reads the keychain.
    public func allowClaudeKeychainAccess() {
        guard let claude = providers["claudeCode"] as? ClaudeCodeProvider else { return }
        let now = self.now
        Task {
            await claude.requestKeychainAccess(now: now)
            self.claudeSources = await claude.sourceStatus()
            self.refresh("claudeCode", userInitiated: true)
        }
    }

    /// Switches the fallback off, which drops the sign-in from memory.
    public func forgetClaudeKeychainAccess() {
        settingsStore.update { $0.claude.refreshWhileClosed = false }
    }

    /// Deletes every remembered reading and measured budget from disk.
    public func forgetReadings() {
        archive.clear()
    }
}
