import Foundation

/// When a manually tracked allowance starts over.
public enum ResetSchedule: Codable, Equatable, Sendable {
    case none
    /// Every `hours`, counted from `anchor` (a rolling five-hour window).
    case everyHours(Int, anchor: Date)
    case daily(hour: Int, minute: Int)
    /// `weekday` is Calendar's: 1 = Sunday … 7 = Saturday.
    case weekly(weekday: Int, hour: Int, minute: Int)
    /// A day past the end of a short month resets on its last day.
    case monthly(day: Int, hour: Int, minute: Int)
    case once(Date)

    /// The first reset strictly after `date`, or nil when there is none.
    public func nextReset(after date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .none:
            return nil
        case .once(let when):
            return when > date ? when : nil
        case .everyHours(let hours, let anchor):
            guard hours > 0 else { return nil }
            let period = TimeInterval(hours) * 3600
            if anchor > date { return anchor }
            let elapsed = date.timeIntervalSince(anchor)
            let periods = (elapsed / period).rounded(.down) + 1
            return anchor.addingTimeInterval(periods * period)
        case .daily(let hour, let minute):
            return calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute, second: 0),
                                     matchingPolicy: .nextTime)
        case .weekly(let weekday, let hour, let minute):
            return calendar.nextDate(after: date,
                                     matching: DateComponents(hour: hour, minute: minute, second: 0, weekday: weekday),
                                     matchingPolicy: .nextTime)
        case .monthly(let day, let hour, let minute):
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
            for offset in 0..<3 {
                guard let month = calendar.date(byAdding: .month, value: offset, to: monthStart),
                      let days = calendar.range(of: .day, in: .month, for: month)?.count
                else { continue }
                var parts = calendar.dateComponents([.year, .month], from: month)
                parts.day = min(max(day, 1), days)
                parts.hour = hour
                parts.minute = minute
                parts.second = 0
                if let candidate = calendar.date(from: parts), candidate > date { return candidate }
            }
            return nil
        }
    }

    /// Whether at least one reset has fallen between `lastReset` and `now`.
    public func hasRolledOver(since lastReset: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let lastReset, let next = nextReset(after: lastReset, calendar: calendar) else { return false }
        return next <= now
    }

    public var summary: String {
        switch self {
        case .none:
            return "Never resets"
        case .once(let date):
            return "Resets once, \(date.formatted(date: .abbreviated, time: .shortened))"
        case .everyHours(let hours, _):
            return "Every \(hours) hours"
        case .daily(let hour, let minute):
            return String(format: "Daily at %02d:%02d", hour, minute)
        case .weekly(let weekday, let hour, let minute):
            let name = Calendar.current.weekdaySymbols[max(0, min(6, weekday - 1))]
            return String(format: "\(name)s at %02d:%02d", hour, minute)
        case .monthly(let day, let hour, let minute):
            return String(format: "Monthly on day %d at %02d:%02d", day, hour, minute)
        }
    }
}

public struct ManualWindow: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var limit: Double
    public var used: Double
    /// "requests", "credits", "$" — shown after the numbers.
    public var unit: String
    public var schedule: ResetSchedule
    /// When `used` last went back to zero.
    public var lastReset: Date?

    public init(id: String = UUID().uuidString, label: String, limit: Double, used: Double = 0,
                unit: String = "requests", schedule: ResetSchedule = .none, lastReset: Date? = Date()) {
        self.id = id
        self.label = label
        self.limit = limit
        self.used = used
        self.unit = unit
        self.schedule = schedule
        self.lastReset = lastReset
    }

    /// Nil when there is no positive limit to be a share of.
    public var usedFraction: Double? {
        guard limit > 0 else { return nil }
        return max(0, used / limit)
    }
}

/// A provider you track by hand, for services Brim cannot read.
public struct ManualProviderConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// One or two letters drawn in the ring.
    public var monogram: String
    public var windows: [ManualWindow]
    /// Optional page opened from the ring's menu.
    public var usagePage: String?

    public init(id: String = "manual.\(UUID().uuidString)", name: String, monogram: String? = nil,
                windows: [ManualWindow] = [], usagePage: String? = nil) {
        self.id = id
        self.name = name
        self.monogram = monogram ?? String(name.prefix(1)).uppercased()
        self.windows = windows
        self.usagePage = usagePage
    }

    /// Windows with any reset that has passed since `lastReset` zeroed. Returns
    /// nil when nothing changed, so callers only persist real changes.
    public func rolledOver(now: Date, calendar: Calendar = .current) -> ManualProviderConfig? {
        var copy = self
        var changed = false
        for index in copy.windows.indices {
            let window = copy.windows[index]
            if window.schedule.hasRolledOver(since: window.lastReset, now: now, calendar: calendar) {
                copy.windows[index].used = 0
                copy.windows[index].lastReset = now
                changed = true
            }
        }
        return changed ? copy : nil
    }
}
