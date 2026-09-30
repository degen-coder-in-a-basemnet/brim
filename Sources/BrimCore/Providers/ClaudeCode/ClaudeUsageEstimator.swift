import Foundation

/// Every response and rate-limit record seen in the lookback period, with
/// duplicates folded together.
final class ClaudeUsageLedger {
    private(set) var usage: [String: UsageEvent] = [:]
    private(set) var limits: [LimitEvent] = []

    func ingest(_ entry: ClaudeLogEntry) {
        switch entry {
        case .usage(let event):
            if let existing = usage[event.key] {
                var merged = existing
                merged.tokens = existing.tokens.merged(with: event.tokens)
                usage[event.key] = merged
            } else {
                usage[event.key] = event
            }
        case .limit(let event):
            // One window rejects many requests; keep the first rejection of each.
            if let index = limits.firstIndex(where: { $0.type == event.type && $0.resetsAt == event.resetsAt }) {
                if event.timestamp < limits[index].timestamp { limits[index] = event }
            } else {
                limits.append(event)
            }
        }
    }

    func prune(before cutoff: Date) {
        usage = usage.filter { $0.value.timestamp >= cutoff }
        limits.removeAll { $0.resetsAt < cutoff }
    }

    var sortedUsage: [UsageEvent] {
        usage.values.sorted { $0.timestamp < $1.timestamp }
    }
}

/// A five-hour stretch of activity, the way Anthropic meters sessions: it opens
/// with the first request after the previous one closed and runs five hours.
struct UsageBlock: Equatable {
    var start: Date
    var end: Date
    var lastActivity: Date
    var tokens: TokenCounts
    var responses: Int

    func contains(_ date: Date) -> Bool { date >= start && date < end }
}

/// Budgets worked out from Anthropic's own figures: a window it refused a
/// request in (spent = 100%), or a percentage it reported (spent = that much).
public struct ClaudeCalibration: Codable, Equatable, Sendable {
    public var sessionBudget: Double?
    public var sessionMeasuredAt: Date?
    public var weeklyBudget: Double?
    public var weeklyMeasuredAt: Date?

    public init(sessionBudget: Double? = nil, sessionMeasuredAt: Date? = nil,
                weeklyBudget: Double? = nil, weeklyMeasuredAt: Date? = nil) {
        self.sessionBudget = sessionBudget
        self.sessionMeasuredAt = sessionMeasuredAt
        self.weeklyBudget = weeklyBudget
        self.weeklyMeasuredAt = weeklyMeasuredAt
    }

    /// The latest measurement wins. One taken at the same moment replaces the
    /// stored one too: it is the same figure worked out from logs read further.
    func updated(with newer: ClaudeCalibration) -> ClaudeCalibration {
        var result = self
        if let at = newer.sessionMeasuredAt, at >= (sessionMeasuredAt ?? .distantPast) {
            result.sessionBudget = newer.sessionBudget
            result.sessionMeasuredAt = at
        }
        if let at = newer.weeklyMeasuredAt, at >= (weeklyMeasuredAt ?? .distantPast) {
            result.weeklyBudget = newer.weeklyBudget
            result.weeklyMeasuredAt = at
        }
        return result
    }
}

/// Turns a ledger, and whatever Anthropic has said, into limit windows. Pure:
/// everything it needs is passed in.
enum ClaudeUsageEstimator {
    static let sessionLength: TimeInterval = 5 * 3600
    static let weekLength: TimeInterval = 7 * 86_400
    /// A derived estimate never claims the limit is spent — only Anthropic can.
    static let derivedCeiling = 0.99
    /// Below this, a reported percentage is too coarse to size a budget from:
    /// Anthropic reports whole percents.
    static let minimumSessionAnchor = 0.15
    static let minimumWeeklyAnchor = 0.10

    /// Groups responses into sessions. Where Anthropic has said when a window
    /// resets, that pins it; otherwise a window opens at its first response.
    /// Windows never overlap, so a reported one also cuts short a guessed one
    /// that would run into it.
    static func blocks(from events: [UsageEvent], knownEnds: [Date] = []) -> [UsageBlock] {
        let ends = knownEnds.sorted()
        var result: [UsageBlock] = []
        for event in events {
            if var current = result.last, event.timestamp < current.end {
                current.tokens = current.tokens + event.tokens
                current.responses += 1
                current.lastActivity = max(current.lastActivity, event.timestamp)
                result[result.count - 1] = current
                continue
            }
            let time = event.timestamp
            var start = time
            var end = time.addingTimeInterval(sessionLength)
            if let reported = ends.first(where: { $0 > time && $0 <= time.addingTimeInterval(sessionLength) }) {
                start = reported.addingTimeInterval(-sessionLength)
                end = reported
            } else if let next = ends.first(where: { $0.addingTimeInterval(-sessionLength) > time }),
                      next.addingTimeInterval(-sessionLength) < end {
                end = next.addingTimeInterval(-sessionLength)
            }
            result.append(UsageBlock(start: start, end: end, lastActivity: time, tokens: event.tokens, responses: 1))
        }
        return result
    }

    /// Every session reset Anthropic has told us about.
    static func sessionEnds(limits: [LimitEvent], official: [OfficialReading]) -> [Date] {
        limits.filter { $0.type == "five_hour" }.map(\.resetsAt)
            + official.compactMap { $0.windows["session"]?.resetsAt }
    }

    /// The rejection still in force for a window type, if any.
    static func activeLimit(_ limits: [LimitEvent], typePrefix: String, now: Date) -> LimitEvent? {
        limits.filter { $0.type.hasPrefix(typePrefix) && $0.resetsAt > now }
            .max { $0.resetsAt < $1.resetsAt }
    }

    static func tokens(_ events: [UsageEvent], from start: Date, to end: Date) -> (TokenCounts, Int) {
        var total = TokenCounts()
        var count = 0
        for event in events where event.timestamp >= start && event.timestamp < end {
            total = total + event.tokens
            count += 1
        }
        return (total, count)
    }

    /// Responses logged after `moment`, up to and including `now`.
    static func tokens(_ events: [UsageEvent], after moment: Date, through now: Date) -> (TokenCounts, Int) {
        var total = TokenCounts()
        var count = 0
        for event in events where event.timestamp > moment && event.timestamp <= now {
            total = total + event.tokens
            count += 1
        }
        return (total, count)
    }

    /// The next weekly reset, projected from any weekly reset ever seen: the
    /// week rolls over at the same moment every seven days.
    static func nextWeeklyReset(anchors: [Date], now: Date) -> Date? {
        guard let anchor = anchors.max() else { return nil }
        if anchor > now { return anchor }
        let weeks = (now.timeIntervalSince(anchor) / weekLength).rounded(.down) + 1
        return anchor.addingTimeInterval(weeks * weekLength)
    }

    // MARK: Calibration

    private struct Measurement {
        var at: Date
        var budget: Double
        /// Measured between two readings rather than from the window's start.
        var marginal = false
    }

    /// Two readings of one window: the rise between them, over what was logged
    /// in between. Unlike a single reading this leaves out whatever happened
    /// before the first, and it prices usage the logs never see (other
    /// devices, background tools) at the rate it is happening now.
    private static func marginalMeasurements(_ readings: [OfficialReading], id: String, minimum: Double,
                                             events: [UsageEvent]) -> [Measurement] {
        let ordered = readings.filter { $0.windows[id]?.resetsAt != nil }.sorted { $0.at < $1.at }
        return zip(ordered, ordered.dropFirst()).compactMap { earlier, later in
            guard let first = earlier.windows[id], let second = later.windows[id],
                  let firstReset = first.resetsAt, let secondReset = second.resetsAt,
                  abs(firstReset.timeIntervalSince(secondReset)) < 120,
                  second.fraction - first.fraction >= minimum else { return nil }
            let (spent, _) = tokens(events, after: earlier.at, through: later.at)
            guard spent.weighted > 0 else { return nil }
            return Measurement(at: later.at, budget: spent.weighted / (second.fraction - first.fraction), marginal: true)
        }
    }

    /// Budgets measured from everything the ledger covers completely: each
    /// limit hit, and each percentage Anthropic reported. The latest wins.
    static func calibration(events: [UsageEvent], limits: [LimitEvent], official: [OfficialReading] = [],
                            coverageStart: Date) -> ClaudeCalibration {
        var session: [Measurement] = []
        var weekly: [Measurement] = []

        for hit in limits where hit.type == "five_hour" {
            let start = hit.resetsAt.addingTimeInterval(-sessionLength)
            guard start >= coverageStart else { continue }
            let (spent, _) = tokens(events, from: start, to: hit.timestamp.addingTimeInterval(1))
            if spent.weighted > 0 { session.append(Measurement(at: hit.timestamp, budget: spent.weighted)) }
        }
        for hit in limits where hit.type == "seven_day" {
            let start = hit.resetsAt.addingTimeInterval(-weekLength)
            guard start >= coverageStart else { continue }
            let (spent, _) = tokens(events, from: start, to: hit.timestamp.addingTimeInterval(1))
            if spent.weighted > 0 { weekly.append(Measurement(at: hit.timestamp, budget: spent.weighted)) }
        }
        for reading in official {
            if let window = reading.windows["session"], let resets = window.resetsAt,
               window.fraction >= minimumSessionAnchor, resets > reading.at {
                let start = resets.addingTimeInterval(-sessionLength)
                if start >= coverageStart {
                    let (spent, _) = tokens(events, from: start, to: reading.at.addingTimeInterval(0.001))
                    if spent.weighted > 0 {
                        session.append(Measurement(at: reading.at, budget: spent.weighted / window.fraction))
                    }
                }
            }
            if let window = reading.windows["weekly_all"], let resets = window.resetsAt,
               window.fraction >= minimumWeeklyAnchor, resets > reading.at {
                let start = resets.addingTimeInterval(-weekLength)
                if start >= coverageStart {
                    let (spent, _) = tokens(events, from: start, to: reading.at.addingTimeInterval(0.001))
                    if spent.weighted > 0 {
                        weekly.append(Measurement(at: reading.at, budget: spent.weighted / window.fraction))
                    }
                }
            }
        }

        session += marginalMeasurements(official, id: "session", minimum: minimumSessionAnchor, events: events)
        weekly += marginalMeasurements(official, id: "weekly_all", minimum: minimumWeeklyAnchor, events: events)

        // The latest wins; at the same moment, a marginal measurement does.
        func latest(_ items: [Measurement]) -> Measurement? {
            items.max { ($0.at, $0.marginal ? 1 : 0) < ($1.at, $1.marginal ? 1 : 0) }
        }
        var result = ClaudeCalibration()
        if let latest = latest(session) {
            result.sessionBudget = latest.budget
            result.sessionMeasuredAt = latest.at
        }
        if let latest = latest(weekly) {
            result.weeklyBudget = latest.budget
            result.weeklyMeasuredAt = latest.at
        }
        return result
    }

    struct Budgets: Equatable {
        var session: Double?
        var weekly: Double?
        /// Where the session budget came from, for the tooltip's source line.
        var sessionOrigin: Origin = .none
        var weeklyOrigin: Origin = .none

        enum Origin: Equatable {
            case none
            case user
            case calibrated(Date)
        }
    }

    static func budgets(settings: ClaudeSettings, calibration: ClaudeCalibration?) -> Budgets {
        var budgets = Budgets()
        if let user = settings.sessionBudget, user > 0 {
            budgets.session = user
            budgets.sessionOrigin = .user
        } else if settings.calibrateFromLimitHits, let measured = calibration?.sessionBudget,
                  let at = calibration?.sessionMeasuredAt {
            budgets.session = measured
            budgets.sessionOrigin = .calibrated(at)
        }
        if let user = settings.weeklyBudget, user > 0 {
            budgets.weekly = user
            budgets.weeklyOrigin = .user
        } else if settings.calibrateFromLimitHits, let measured = calibration?.weeklyBudget,
                  let at = calibration?.weeklyMeasuredAt {
            budgets.weekly = measured
            budgets.weeklyOrigin = .calibrated(at)
        }
        return budgets
    }

    // MARK: Windows

    static func windows(events: [UsageEvent], limits: [LimitEvent], official: OfficialReading? = nil,
                        now: Date, budgets: Budgets) -> [LimitWindow] {
        var windows: [LimitWindow] = []
        let readings = official.map { [$0] } ?? []
        let block = blocks(from: events, knownEnds: sessionEnds(limits: limits, official: readings))
            .last { $0.contains(now) }
        let sessionDetail = block.map { "\(CountFormat.compact($0.tokens.total)) tokens · \($0.responses) responses" }

        // Current session.
        if let hit = activeLimit(limits, typePrefix: "five_hour", now: now) {
            let start = hit.resetsAt.addingTimeInterval(-sessionLength)
            let (spent, _) = tokens(events, from: start, to: now.addingTimeInterval(1))
            windows.append(LimitWindow(
                id: "session", label: "Current session", usedFraction: 1, resetsAt: hit.resetsAt,
                duration: sessionLength, detail: "\(CountFormat.compact(spent.total)) tokens",
                fidelity: .official,
                note: "Limit reached — reported by Anthropic at \(hit.timestamp.formatted(date: .omitted, time: .shortened))"))
        } else if let reading = official, let anchor = reading.windows["session"],
                  let resets = anchor.resetsAt, resets > now {
            windows.append(anchored(id: "session", label: "Current session", anchor: anchor, resetsAt: resets,
                                    duration: sessionLength, reading: reading, events: events, now: now,
                                    budget: budgets.session, detail: sessionDetail ?? "No Claude Code use this window"))
        } else {
            let spent = block?.tokens ?? TokenCounts()
            let fraction = budgets.session.map { min(spent.weighted / $0, derivedCeiling) }
            windows.append(LimitWindow(
                id: "session", label: "Current session", usedFraction: fraction,
                resetsAt: block?.end, duration: sessionLength,
                detail: sessionDetail ?? "No activity in the last 5 hours", fidelity: .derived))
        }

        // The week, across all models.
        if let hit = activeLimit(limits, typePrefix: "seven_day", now: now), hit.type == "seven_day" {
            windows.append(LimitWindow(
                id: "weekly_all", label: "All models", usedFraction: 1, resetsAt: hit.resetsAt,
                duration: weekLength, fidelity: .official,
                note: "Limit reached — reported by Anthropic"))
        } else if let reading = official, let anchor = reading.windows["weekly_all"],
                  let resets = anchor.resetsAt, resets > now {
            let (spent, _) = tokens(events, from: resets.addingTimeInterval(-weekLength), to: now.addingTimeInterval(1))
            windows.append(anchored(id: "weekly_all", label: "All models", anchor: anchor, resetsAt: resets,
                                    duration: weekLength, reading: reading, events: events, now: now,
                                    budget: budgets.weekly, detail: "\(CountFormat.compact(spent.total)) tokens"))
        } else {
            let anchors = limits.filter { $0.type == "seven_day" }.map(\.resetsAt)
                + readings.compactMap { $0.windows["weekly_all"]?.resetsAt }
            let reset = nextWeeklyReset(anchors: anchors, now: now)
            let start = reset.map { $0.addingTimeInterval(-weekLength) } ?? now.addingTimeInterval(-weekLength)
            let (spent, _) = tokens(events, from: start, to: now.addingTimeInterval(1))
            let fraction = budgets.weekly.map { min(spent.weighted / $0, derivedCeiling) }
            windows.append(LimitWindow(
                id: "weekly_all", label: reset == nil ? "Last 7 days" : "All models",
                usedFraction: fraction, resetsAt: reset, duration: weekLength,
                detail: "\(CountFormat.compact(spent.total)) tokens", fidelity: .derived))
        }

        // Model-specific weekly caps: once enforced, or as Anthropic reported them.
        for hit in limits where hit.type.hasPrefix("seven_day_") && hit.resetsAt > now {
            let id = "weekly_" + hit.type.dropFirst("seven_day_".count)
            guard !windows.contains(where: { $0.id == id }) else { continue }
            windows.append(LimitWindow(
                id: id, label: hit.type.dropFirst("seven_day_".count).capitalized, usedFraction: 1,
                resetsAt: hit.resetsAt, duration: weekLength, fidelity: .official,
                note: "Limit reached — reported by Anthropic"))
        }
        if let reading = official {
            for (id, label) in [("weekly_opus", "Opus"), ("weekly_sonnet", "Sonnet")] {
                guard let window = reading.windows[id], !windows.contains(where: { $0.id == id }),
                      (window.resetsAt ?? .distantFuture) > now else { continue }
                windows.append(LimitWindow(
                    id: id, label: label, usedFraction: window.fraction, resetsAt: window.resetsAt,
                    duration: weekLength, fidelity: .official, note: reportedNote(reading)))
            }
        }
        return windows
    }

    /// Anthropic's figure, carried forward by what Claude Code has logged since
    /// it was taken. With nothing logged since, it stands as reported.
    static func anchored(id: String, label: String, anchor: OfficialWindow, resetsAt: Date,
                         duration: TimeInterval, reading: OfficialReading, events: [UsageEvent], now: Date,
                         budget: Double?, detail: String) -> LimitWindow {
        let (since, count) = tokens(events, after: reading.at, through: now)
        let official = LimitWindow(id: id, label: label, usedFraction: anchor.fraction, resetsAt: resetsAt,
                                   duration: duration, detail: detail, fidelity: .official)
        guard count > 0, since.weighted > 0 else {
            var window = official
            window.note = reportedNote(reading)
            return window
        }
        guard let budget, budget > 0 else {
            var window = official
            window.note = "Anthropic: \(Percent.text(for: anchor.fraction)) at \(time(reading.at)), more used since"
            return window
        }
        let ceiling = max(anchor.fraction, derivedCeiling)
        return LimitWindow(id: id, label: label, usedFraction: min(anchor.fraction + since.weighted / budget, ceiling),
                           resetsAt: resetsAt, duration: duration, detail: detail, fidelity: .derived,
                           note: "Anthropic said \(Percent.text(for: anchor.fraction)) at \(time(reading.at))")
    }

    static func reportedNote(_ reading: OfficialReading) -> String {
        "Reported by Anthropic at \(time(reading.at))"
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
