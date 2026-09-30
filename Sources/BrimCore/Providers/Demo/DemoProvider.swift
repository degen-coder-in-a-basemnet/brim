import Foundation

/// Fixed sample data for looking at the UI without reading anything.
///
/// Every figure is a function of the clock and nothing else, so two runs at the
/// same moment draw the same notch — which is what the snapshot renderer and
/// the tests rely on. Sessions cycle through working, waiting and finished on a
/// fixed timetable so the peek and the activity arcs can be watched.
public enum DemoData {
    /// The demo's providers, in notch order.
    public static let ids = ["demo.claude", "demo.codex", "demo.cursor", "demo.ollama"]

    public static func snapshots(now: Date) -> [ProviderSnapshot] {
        ids.map { snapshot(id: $0, now: now) }
    }

    public static func snapshot(id: String, now: Date) -> ProviderSnapshot {
        switch id {
        case "demo.claude":
            return ProviderSnapshot(
                id: id, kind: .demo, displayName: "Claude", glyph: .asterisk, fidelity: .official,
                windows: [
                    LimitWindow(id: "session", label: "Current session", usedFraction: 0.73,
                                resetsAt: now.addingTimeInterval(51 * 60), duration: 5 * 3600,
                                detail: "4.1M tokens · 318 responses", fidelity: .official),
                    LimitWindow(id: "weekly_all", label: "All models", usedFraction: 0.07,
                                resetsAt: nextWeekday(5, hour: 0, after: now), duration: 7 * 86_400,
                                fidelity: .official),
                ],
                capturedAt: now, status: .ok, source: "Demo data", plan: "Max",
                preferredHeadlineID: "session")
        case "demo.codex":
            return ProviderSnapshot(
                id: id, kind: .demo, displayName: "Codex", glyph: .prompt, fidelity: .official,
                windows: [
                    LimitWindow(id: "primary", label: "5-hour limit", usedFraction: 0.21,
                                resetsAt: now.addingTimeInterval(3 * 3600 + 12 * 60), fidelity: .official),
                    LimitWindow(id: "secondary", label: "Weekly limit", usedFraction: 0.12,
                                resetsAt: now.addingTimeInterval(4 * 86_400 + 5 * 3600), fidelity: .official),
                ],
                capturedAt: now, status: .ok, source: "Demo data", plan: "Pro")
        case "demo.cursor":
            return ProviderSnapshot(
                id: id, kind: .demo, displayName: "Cursor", glyph: .monogram("C"), fidelity: .manual,
                windows: [
                    LimitWindow(id: "monthly", label: "Premium requests", usedFraction: 0.52,
                                resetsAt: now.addingTimeInterval(12 * 86_400), detail: "260 of 500 requests",
                                fidelity: .manual),
                ],
                capturedAt: now, status: .ok, source: "Demo data (manual provider)")
        default:
            return ProviderSnapshot(
                id: id, kind: .demo, displayName: "Ollama", glyph: .symbol("cube.transparent"), fidelity: .local,
                windows: [
                    LimitWindow(id: "memory", label: "Memory in use by models", usedFraction: 0.16,
                                detail: "5.1 GB of 32 GB", fidelity: .local),
                    LimitWindow(id: "model.llama", label: "llama3.2:3b",
                                detail: "2.0 GB · 100% GPU · 4K ctx · unloads in 4m", fidelity: .local),
                    LimitWindow(id: "model.qwen", label: "qwen3:8b",
                                detail: "3.1 GB · 100% GPU · 8K ctx · unloads in 2m", fidelity: .local),
                ],
                capturedAt: now, status: .ok, source: "Demo data (local runtime)",
                cellLabel: "2 models", preferredHeadlineID: "memory")
        }
    }

    /// A 60-second timetable per session, offset so they rarely coincide:
    /// working for 20 s, waiting for 12 s, finished for 8 s, then idle.
    public static func sessions(now: Date) -> [AgentSession] {
        let second = Int(now.timeIntervalSince1970)
        func phase(_ offset: Int) -> (SessionState, Date) {
            let t = (second + offset) % 60
            let start = now.addingTimeInterval(-Double(t))
            switch t {
            case 0..<20:  return (.busy, start)
            case 20..<32: return (.waiting, start.addingTimeInterval(20))
            case 32..<40: return (.finished, start.addingTimeInterval(32))
            default:      return (.idle, start.addingTimeInterval(40))
            }
        }
        let (claudeState, claudeSince) = phase(0)
        let (codexState, codexSince) = phase(27)
        return [
            AgentSession(id: "demo.claude.1", providerID: "demo.claude", name: "brim", detail: "Terminal · brim",
                         state: claudeState, since: claudeSince,
                         waitingFor: claudeState == .waiting ? "Permission to run a command" : nil),
            AgentSession(id: "demo.claude.2", providerID: "demo.claude", name: "website",
                         detail: "VS Code · website", state: .idle, since: now.addingTimeInterval(-25 * 60)),
            AgentSession(id: "demo.codex.1", providerID: "demo.codex", name: "api", detail: "Terminal · api",
                         state: codexState, since: codexSince),
        ]
    }

    static func nextWeekday(_ weekday: Int, hour: Int, after date: Date) -> Date {
        Calendar.current.nextDate(after: date, matching: DateComponents(hour: hour, minute: 0, weekday: weekday),
                                  matchingPolicy: .nextTime) ?? date.addingTimeInterval(3 * 86_400)
    }
}

/// One demo provider instance.
public actor DemoProvider: UsageProvider {
    public nonisolated let id: String
    public nonisolated let kind = ProviderKind.demo
    public nonisolated let displayName: String

    public init(id: String) {
        self.id = id
        self.displayName = DemoData.snapshot(id: id, now: Date()).displayName
    }

    public func fetchSnapshot(now: Date) async -> ProviderSnapshot {
        DemoData.snapshot(id: id, now: now)
    }

    public func sessions(now: Date) async -> [AgentSession] {
        DemoData.sessions(now: now).filter { $0.providerID == id }
    }
}
