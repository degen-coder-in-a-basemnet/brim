// Adapted from Codenotch (https://github.com/vinzdg/codenotch), MIT License,
// Copyright (c) 2026 Vinz. See THIRD_PARTY_NOTICES.md.
import Foundation

public enum ResetTimeFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Minutes under an hour, otherwise the reset's date and time.
    case automatic
    /// Always a countdown: "Resets in 3 Days 3h", "Resets in 3h 20m".
    case remaining

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: return "Reset date"
        case .remaining: return "Time remaining"
        }
    }
}

/// "Resets in 51 min" under an hour, "Resets Thu 12:00 AM" within the week,
/// "Resets Sep 28" beyond it.
public enum ResetCopy {
    public static func text(for resetsAt: Date, now: Date, calendar: Calendar = .current,
                            format: ResetTimeFormat = .automatic, locale: Locale = .current) -> String {
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return "Resetting…" }

        if format == .remaining {
            let minutes = max(1, Int((seconds / 60).rounded()))
            let hours = minutes / 60
            let days = hours / 24
            if days > 0 {
                return days == 1 ? "Resets in 1 Day \(hours % 24)h" : "Resets in \(days) Days \(hours % 24)h"
            }
            if hours > 0 { return "Resets in \(hours)h \(minutes % 60)m" }
            return "Resets in \(minutes) min"
        }

        // Rounded, so 50m40s reads 51. Something that rounds to 60 falls through
        // to the absolute form, so "Resets in 60 min" never appears.
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "Resets in \(max(1, minutes)) min" }

        let formatter = formatter(for: calendar, locale: locale)
        // A weekday only names a day inside the coming week; further out it
        // would read as this week's.
        if daysApart(from: now, to: resetsAt, calendar: calendar) >= 7 {
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
            return "Resets \(formatter.string(from: resetsAt))"
        }
        // `j` follows the region's 12/24-hour choice.
        formatter.setLocalizedDateFormatFromTemplate("E j:mm")
        return "Resets \(formatter.string(from: resetsAt))"
    }

    /// The short countdown the menu bar uses: "2h 05m", "47m", "<1m".
    /// Truncated, never rounded up: it is read against a clock.
    public static func countdown(to resetsAt: Date, now: Date) -> String? {
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours >= 48 { return "\(hours / 24)d \(hours % 24)h" }
        return "\(hours)h \(String(format: "%02d", minutes % 60))m"
    }

    static func formatter(for calendar: Calendar, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        return formatter
    }

    /// Whole calendar days between two instants.
    static func daysApart(from: Date, to: Date, calendar: Calendar) -> Int {
        let start = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: to)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }
}

/// "just now", "4 min ago", "3h ago" for readings; "for 3m" for sessions.
public enum ElapsedCopy {
    public static func ago(since: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    public static func duration(since: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        if seconds < 60 { return "\(Int(seconds))s" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d"
    }
}

/// Compact counts for tooltips: 950, 12.4K, 4.1M, 2.3B.
public enum CountFormat {
    public static func compact(_ value: Double) -> String {
        let magnitude = abs(value)
        func trimmed(_ number: Double, _ suffix: String) -> String {
            let text = number >= 100 ? String(format: "%.0f", number) : String(format: "%.1f", number)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
        }
        switch magnitude {
        case ..<1_000:          return String(format: "%.0f", value)
        case ..<1_000_000:      return trimmed(value / 1_000, "K")
        case ..<1_000_000_000:  return trimmed(value / 1_000_000, "M")
        default:                return trimmed(value / 1_000_000_000, "B")
        }
    }

    public static func compact(_ value: Int) -> String { compact(Double(value)) }

    public static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }
}
