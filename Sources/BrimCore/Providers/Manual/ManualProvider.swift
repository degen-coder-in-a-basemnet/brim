import Foundation

/// A provider tracked by hand. Its numbers are exactly what was entered, so
/// the percentage is real arithmetic on real inputs — labelled `manual`, not
/// passed off as the vendor's.
public actor ManualProvider: UsageProvider {
    public nonisolated let id: String
    public nonisolated let kind = ProviderKind.manual
    public nonisolated let displayName: String
    private var config: ManualProviderConfig

    public init(config: ManualProviderConfig) {
        self.id = config.id
        self.displayName = config.name
        self.config = config
    }

    public func update(config: ManualProviderConfig) { self.config = config }

    public func fetchSnapshot(now: Date) async -> ProviderSnapshot {
        Self.snapshot(config: config, now: now)
    }

    public static func snapshot(config: ManualProviderConfig, now: Date) -> ProviderSnapshot {
        guard !config.windows.isEmpty else {
            return ProviderSnapshot(id: config.id, kind: .manual, displayName: config.name,
                                    glyph: .monogram(config.monogram), fidelity: .manual, capturedAt: now,
                                    status: .unavailable("No limits entered yet. Add one in Settings → Providers."))
        }
        let windows = config.windows.map { window -> LimitWindow in
            let used = Self.format(window.used)
            let limit = Self.format(window.limit)
            let unit = window.unit.isEmpty ? "" : " \(window.unit)"
            return LimitWindow(id: window.id, label: window.label, usedFraction: window.usedFraction,
                               resetsAt: window.schedule.nextReset(after: now),
                               detail: "\(used) of \(limit)\(unit)", fidelity: .manual)
        }
        return ProviderSnapshot(id: config.id, kind: .manual, displayName: config.name,
                                glyph: .monogram(config.monogram), fidelity: .manual, windows: windows,
                                capturedAt: now, status: .ok, source: "Entered by you in Settings")
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}
