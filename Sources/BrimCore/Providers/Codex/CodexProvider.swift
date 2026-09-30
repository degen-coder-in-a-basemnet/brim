import Foundation

/// Codex, read from its own session logs.
///
/// Every response Codex receives carries the account's rate-limit state, and
/// Codex writes it into `~/.codex/sessions/…/rollout-*.jsonl`. Those are the
/// server's figures, so they are `official` — but only as new as the last
/// request, which is why they dim once Codex has been quiet for a while.
public actor CodexProvider: UsageProvider {
    public nonisolated let id = "codex"
    public nonisolated let kind = ProviderKind.codex
    public nonisolated let displayName = "Codex"

    static let finishedHold: TimeInterval = 8
    static let quietLimit: TimeInterval = 20 * 60
    static let sessionHorizon: TimeInterval = 30 * 60

    private let scanner: CodexRolloutScanner
    private let processes: CodexProcessFinder
    private var lastScan: Date?

    public init(environment: ProviderEnvironment, files: LocalFileAccess) {
        scanner = CodexRolloutScanner(files: files, codexDirectory: environment.codexDirectory)
        processes = .system
    }

    private func scanIfDue(now: Date, minimumGap: TimeInterval) {
        if let lastScan, now.timeIntervalSince(lastScan) < minimumGap { return }
        scanner.scan(now: now)
        lastScan = now
    }

    public func fetchSnapshot(now: Date) async -> ProviderSnapshot {
        guard scanner.hasSessions else {
            return statusSnapshot(.unavailable("No Codex sessions in ~/.codex/sessions yet."), now: now)
        }
        scanIfDue(now: now, minimumGap: 0)
        guard let limits = scanner.latestLimits else {
            return statusSnapshot(.unavailable("Codex hasn't recorded its rate limits in the last week."), now: now)
        }
        return ProviderSnapshot(
            id: id, kind: kind, displayName: displayName, glyph: .prompt, fidelity: .official,
            windows: Self.windows(from: limits, now: now), capturedAt: limits.timestamp, status: .ok,
            source: "Server figures from Codex's session log",
            plan: limits.planType.map(Self.planName))
    }

    static func windows(from limits: CodexRateLimits, now: Date) -> [LimitWindow] {
        var result: [LimitWindow] = []
        for (slot, window) in [("primary", limits.primary), ("secondary", limits.secondary)] {
            guard let window else { continue }
            let label = label(minutes: window.windowMinutes, fallback: slot == "primary" ? "Current limit" : "Longer limit")
            let duration = window.windowMinutes.map { TimeInterval($0) * 60 }
            if let resetsAt = window.resetsAt, resetsAt <= now {
                // The window rolled over after Codex last reported. Nothing
                // Codex did since is on record, so the new window reads empty —
                // an inference, and marked as one.
                let next = duration.flatMap { nextReset(after: resetsAt, period: $0, now: now) }
                result.append(LimitWindow(id: slot, label: label, usedFraction: 0, resetsAt: next,
                                          duration: duration, fidelity: .derived,
                                          note: "Reset since Codex last reported"))
            } else {
                result.append(LimitWindow(id: slot, label: label, usedFraction: window.usedPercent / 100,
                                          resetsAt: window.resetsAt, duration: duration, fidelity: .official))
            }
        }
        return result
    }

    static func nextReset(after reset: Date, period: TimeInterval, now: Date) -> Date? {
        guard period > 0 else { return nil }
        let periods = (now.timeIntervalSince(reset) / period).rounded(.down) + 1
        return reset.addingTimeInterval(periods * period)
    }

    static func label(minutes: Int?, fallback: String) -> String {
        guard let minutes, minutes > 0 else { return fallback }
        switch minutes {
        case 300:           return "5-hour limit"
        case 10_080:        return "Weekly limit"
        case ..<1_440:      return "\(minutes / 60)-hour limit"
        case 43_200...44_640: return "Monthly limit"
        default:            return "\(minutes / 1_440)-day limit"
        }
    }

    static func planName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    public func sessions(now: Date) async -> [AgentSession] {
        guard scanner.hasSessions else { return [] }
        scanIfDue(now: now, minimumGap: 2)
        let traces = scanner.traces
        guard traces.values.contains(where: { now.timeIntervalSince($0.modified) < Self.sessionHorizon }) else { return [] }
        return Self.sessions(from: traces, providerID: id, now: now, owners: processes.owners())
    }

    /// `owners` maps a session's key to the process writing its rollout file:
    /// the session's process id, for bringing its app forward.
    static func sessions(from traces: [String: CodexRolloutScanner.SessionTrace], providerID: String,
                         now: Date, owners: [String: Int32] = [:]) -> [AgentSession] {
        traces.compactMap { key, trace -> AgentSession? in
            guard now.timeIntervalSince(trace.modified) < sessionHorizon, let activity = trace.lastActivity else {
                return nil
            }
            let state: SessionState
            switch activity.kind {
            case "task_started":
                state = now.timeIntervalSince(trace.modified) > quietLimit ? .stale : .busy
            case "exec_approval_request", "apply_patch_approval_request", "request_user_input":
                state = .waiting
            default:
                state = now.timeIntervalSince(activity.at) < finishedHold ? .finished : .idle
            }
            let folder = trace.cwd.map { ($0 as NSString).lastPathComponent } ?? "Codex"
            let surface = (trace.originator ?? "").lowercased().contains("desktop") ? "Codex app" : "Terminal"
            return AgentSession(id: "codex.\(key)", providerID: providerID, name: folder,
                                detail: "\(surface) · \(folder)", state: state, since: activity.at,
                                processID: owners[key])
        }
    }
}
