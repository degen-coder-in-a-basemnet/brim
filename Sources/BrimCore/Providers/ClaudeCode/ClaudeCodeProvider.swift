import Foundation

/// Claude Code, read from its own files.
///
/// Anthropic's own percentages come first, from whichever source reported
/// last: Claude Code's status line (through the handoff file its command
/// writes), the copy Claude Code caches in ~/.claude.json whenever it fetches
/// usage, and, only if the user switches them on, the installed `claude`
/// binary's `/usage` or Anthropic's usage endpoint asked with Claude Code's
/// sign-in while Claude Code is closed. The latest figure anchors each window;
/// responses logged since move it on as an estimate (`derived`). With no figure
/// at all, the transcripts' token counts and rate-limit rejections carry it.
public actor ClaudeCodeProvider: UsageProvider {
    public nonisolated let id = "claudeCode"
    public nonisolated let kind = ProviderKind.claudeCode
    public nonisolated let displayName = "Claude Code"

    private let environment: ProviderEnvironment
    private let files: LocalFileAccess
    private let scanner: ClaudeTranscriptScanner
    private let monitor: ClaudeSessionMonitor
    private let runner: ProcessRunner
    private let fallback: ClaudeUsageFallback
    private let persistCalibration: @Sendable (ClaudeCalibration) -> Void
    private var settings: ClaudeSettings
    private var showSessionTitles: Bool
    private var calibration: ClaudeCalibration

    private var handoff: (file: FileInfo, reading: OfficialReading?)?
    private var cached: (file: FileInfo, reading: OfficialReading?)?
    /// Recent official readings, kept in memory only, so two of one window can
    /// size the budget between them.
    private var officialHistory: [OfficialReading] = []
    private var cliReading: (reading: ClaudeUsageCLI.Reading, at: Date)?
    private var cliLastAttempt: Date?
    private var cliProblem: String?

    public init(environment: ProviderEnvironment, files: LocalFileAccess, settings: ClaudeSettings,
                showSessionTitles: Bool, calibration: ClaudeCalibration?,
                runner: ProcessRunner = ProcessRunner(),
                persistCalibration: @escaping @Sendable (ClaudeCalibration) -> Void = { _ in }) {
        self.init(environment: environment, files: files, settings: settings, showSessionTitles: showSessionTitles,
                  calibration: calibration, runner: runner, credentials: SystemClaudeKeychain(),
                  endpoint: AnthropicUsageClient(), persistCalibration: persistCalibration)
    }

    init(environment: ProviderEnvironment, files: LocalFileAccess, settings: ClaudeSettings,
         showSessionTitles: Bool, calibration: ClaudeCalibration?, runner: ProcessRunner = ProcessRunner(),
         credentials: ClaudeCredentialStore, endpoint: ClaudeUsageEndpoint,
         persistCalibration: @escaping @Sendable (ClaudeCalibration) -> Void = { _ in }) {
        self.environment = environment
        self.fallback = ClaudeUsageFallback(credentials: credentials, endpoint: endpoint)
        self.files = files
        self.scanner = ClaudeTranscriptScanner(files: files, claudeDirectory: environment.claudeDirectory)
        self.monitor = ClaudeSessionMonitor(files: files, claudeDirectory: environment.claudeDirectory)
        self.monitor.ignoredDirectories = [ClaudeUsageCLI.scratchDirectory(applicationSupport: environment.applicationSupport).path]
        self.runner = runner
        self.settings = settings
        self.showSessionTitles = showSessionTitles
        self.calibration = calibration ?? ClaudeCalibration()
        self.persistCalibration = persistCalibration
    }

    public func update(settings: ClaudeSettings, showSessionTitles: Bool) {
        if !settings.useUsageCommand {
            cliReading = nil
            cliProblem = nil
        }
        if !settings.readUsageCache { cached = nil }
        if !settings.refreshWhileClosed { fallback.forget() }
        officialHistory.removeAll {
            ($0.origin == .cache && !settings.readUsageCache) || ($0.origin == .command && !settings.useUsageCommand)
                || ($0.origin == .endpoint && !settings.refreshWhileClosed)
        }
        self.settings = settings
        self.showSessionTitles = showSessionTitles
    }

    public func fetchSnapshot(now: Date) async -> ProviderSnapshot {
        guard scanner.hasProjects else {
            return statusSnapshot(.unavailable("No Claude Code logs in ~/.claude/projects yet."), now: now)
        }
        scanner.scan(now: now)
        let events = scanner.ledger.sortedUsage
        let limits = scanner.ledger.limits

        if settings.useUsageCommand { await refreshCLIIfDue(now: now) }
        var readings = officialReadings()
        if settings.refreshWhileClosed {
            // Only asks Anthropic when nothing on this Mac has reported lately.
            await fallback.poll(now: now, freshestLocal: readings.map(\.at).max(),
                                interval: settings.refreshWhileClosedInterval)
            if let reading = fallback.reading { readings.append(reading) }
        }
        let latest = readings.max { $0.at < $1.at }
        for reading in readings where !officialHistory.contains(where: { $0.at == reading.at }) {
            officialHistory.append(reading)
        }
        officialHistory = Array(officialHistory.sorted { $0.at < $1.at }.suffix(12))

        let measured = ClaudeUsageEstimator.calibration(events: events, limits: limits, official: officialHistory,
                                                        coverageStart: scanner.coverageStart)
        let updated = calibration.updated(with: measured)
        if updated != calibration {
            calibration = updated
            persistCalibration(updated)
        }
        let budgets = ClaudeUsageEstimator.budgets(settings: settings, calibration: calibration)
        let windows = ClaudeUsageEstimator.windows(events: events, limits: limits, official: latest,
                                                   now: now, budgets: budgets)

        let metered = windows.filter { $0.usedFraction != nil }
        let fidelity: Fidelity = !metered.isEmpty && metered.allSatisfy { $0.fidelity == .official } ? .official : .derived
        var source = Self.source(latest: latest, session: windows.first { $0.id == "session" }, budgets: budgets, now: now)
        if settings.useUsageCommand, let cliProblem { source += " · /usage: \(cliProblem)" }

        return ProviderSnapshot(id: id, kind: kind, displayName: displayName, glyph: .asterisk,
                                fidelity: fidelity, windows: windows, capturedAt: now, status: .ok,
                                source: source, plan: latest?.plan, preferredHeadlineID: nil)
    }

    /// Every official figure on hand: Claude Code's cache, and Brim's own
    /// `/usage` run when that is switched on.
    private func officialReadings() -> [OfficialReading] {
        var readings: [OfficialReading] = []
        if let reading = readStatuslineHandoff() { readings.append(reading) }
        if settings.readUsageCache, let reading = readUsageCache() { readings.append(reading) }
        if let cli = cliReading {
            var windows: [String: OfficialWindow] = [:]
            for window in cli.reading.windows {
                if let fraction = window.usedFraction {
                    windows[window.id] = OfficialWindow(fraction: fraction, resetsAt: window.resetsAt)
                }
            }
            readings.append(OfficialReading(at: cli.at, windows: windows, plan: cli.reading.plan, origin: .command))
        }
        return readings
    }

    /// What Claude Code's status line last handed over, if its command writes
    /// the handoff file. Re-read only when the file has changed.
    private func readStatuslineHandoff() -> OfficialReading? {
        let url = ClaudeStatuslineHandoff.url(in: environment.applicationSupport)
        guard let info = files.info(for: url) else {
            handoff = nil
            return nil
        }
        if let handoff, handoff.file == info { return handoff.reading }
        let reading = (try? files.contents(of: url, maxBytes: ClaudeStatuslineHandoff.maxBytes))
            .flatMap(ClaudeStatuslineHandoff.reading(from:))
        handoff = (info, reading)
        return reading
    }

    /// Where Claude's figures are coming from, for Settings.
    public func sourceStatus() -> ClaudeSourceStatus {
        var status = ClaudeSourceStatus()
        status.statuslineReportedAt = handoff?.reading?.at
        status.cacheFetchedAt = cached?.reading?.at
        if settings.refreshWhileClosed {
            status.fallback = fallback.state == .off ? .needsApproval : fallback.state
        }
        return status
    }

    /// Someone clicked "Allow access…", or has just switched the fallback on.
    /// The only path to the keychain.
    public func requestKeychainAccess(now: Date) {
        guard settings.refreshWhileClosed else { return }
        fallback.requestAccess(now: now)
    }

    /// Re-read only when the file has changed since the last pass.
    private func readUsageCache() -> OfficialReading? {
        let url = environment.claudeConfigFile
        guard let info = files.info(for: url) else {
            cached = nil
            return nil
        }
        if let cached, cached.file == info { return cached.reading }
        let reading = (try? files.contents(of: url, maxBytes: ClaudeUsageCache.maxBytes))
            .flatMap(ClaudeUsageCache.reading(from:))
        cached = (info, reading)
        return reading
    }

    private static func source(latest: OfficialReading?, session: LimitWindow?,
                               budgets: ClaudeUsageEstimator.Budgets, now: Date) -> String {
        let anchored = latest.flatMap { $0.windows["session"]?.resetsAt }.map { $0 > now } ?? false
        guard let latest, anchored else { return derivedSource(budgets) }
        let origin: String
        switch latest.origin {
        case .statusline: origin = "Claude Code's status line"
        case .cache: origin = "Claude Code's cache"
        case .command: origin = "claude /usage"
        case .endpoint: origin = "Anthropic's usage endpoint"
        }
        return session?.fidelity == .official
            ? "Anthropic's figures, from \(origin)"
            : "Anthropic's last figures (\(origin)) plus local logs since"
    }

    public func sessions(now: Date) async -> [AgentSession] {
        monitor.sessions(now: now, providerID: id, showTitles: showSessionTitles,
                         lastWrite: { [scanner] in scanner.lastWrite(sessionID: $0) })
    }

    private static func derivedSource(_ budgets: ClaudeUsageEstimator.Budgets) -> String {
        switch budgets.sessionOrigin {
        case .user:
            return "Estimated from Claude Code's local logs against your budget"
        case .calibrated(let date):
            return "Estimated from local logs · budget sized from Anthropic's figures on \(date.formatted(.dateTime.month(.abbreviated).day()))"
        case .none:
            return "Token counts from local logs · set a budget in Settings to see a percentage"
        }
    }

    private func refreshCLIIfDue(now: Date) async {
        let interval = max(settings.usageCommandInterval, 300)
        if let last = cliLastAttempt, now.timeIntervalSince(last) < interval { return }
        cliLastAttempt = now
        guard let binary = ClaudeUsageCLI.locate(home: environment.home) else {
            cliProblem = "claude not found"
            return
        }
        let scratch = ClaudeUsageCLI.scratchDirectory(applicationSupport: environment.applicationSupport)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        do {
            let output = try await runner.run(binary, arguments: ClaudeUsageCLI.arguments, workingDirectory: scratch)
            let text = String(decoding: output, as: UTF8.self)
            cliReading = (try ClaudeUsageCLI.parse(text, now: now), now)
            cliProblem = nil
            SafeLog.providers.info("claude /usage read")
        } catch ProcessRunner.RunError.timedOut {
            cliProblem = "timed out"
        } catch ProcessRunner.RunError.exited {
            cliProblem = "claude is not signed in"
        } catch is ClaudeUsageCLI.ParseError {
            cliProblem = "no usage lines in its output"
        } catch {
            cliProblem = "could not run"
        }
    }
}
