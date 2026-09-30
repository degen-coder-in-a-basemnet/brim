// Output format and date parsing adapted from Codenotch
// (https://github.com/vinzdg/codenotch), MIT License, Copyright (c) 2026 Vinz.
// See THIRD_PARTY_NOTICES.md.
import Foundation

/// Claude Code's own `/usage`, asked of the installed binary.
///
/// Off unless switched on. When on, Claude Code makes the request to
/// api.anthropic.com with its own login; Brim only reads the lines it prints.
/// `--safe-mode` keeps the user's hooks, plugins and MCP servers from starting
/// on every poll, and `--no-session-persistence` keeps it from filing a
/// transcript. It runs from a fixed folder inside Brim's Application Support so
/// its session record can be recognised and left out of the activity list.
struct ClaudeUsageCLI {
    static let arguments = ["--print", "--safe-mode", "--no-session-persistence", "--strict-mcp-config", "/usage"]

    /// Where Claude Code installs itself, relative to the home folder.
    static let homeCandidates = [
        ".local/bin/claude",
        ".claude/local/claude",
        ".npm-global/bin/claude",
        ".bun/bin/claude",
    ]
    static let systemCandidates = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]

    static func locate(home: URL, fileManager: FileManager = .default) -> URL? {
        var candidates = homeCandidates.map { home.appendingPathComponent($0) }
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? fileManager.contentsOfDirectory(atPath: nvm.path) {
            candidates += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { nvm.appendingPathComponent($0).appendingPathComponent("bin/claude") }
        }
        candidates += systemCandidates.map { URL(fileURLWithPath: $0) }
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    static func scratchDirectory(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("claude-usage", isDirectory: true)
    }

    struct Reading: Equatable {
        var windows: [LimitWindow]
        var plan: String?
    }

    enum ParseError: Error { case noSessionLine }

    /// `Current session: 38% used · resets Sep 7 at 2:59pm (Asia/Jakarta)` and
    /// the weekly lines after it. Everything else `/usage` prints is ignored.
    private static let line = try! NSRegularExpression(
        pattern: #"^\s*Current (?:(session)|week \(([^)]+)\)):\s*(\d+(?:\.\d+)?)%\s*used(?:\s*[·•-]\s*resets\s*(.+?))?\s*$"#,
        options: [.anchorsMatchLines, .caseInsensitive])

    static func parse(_ text: String, now: Date) throws -> Reading {
        let range = NSRange(text.startIndex..., in: text)
        var windows: [LimitWindow] = []
        for match in line.matches(in: text, range: range) {
            func group(_ index: Int) -> String? {
                guard let r = Range(match.range(at: index), in: text) else { return nil }
                return String(text[r])
            }
            guard let percent = group(3).flatMap(Double.init) else { continue }
            let isSession = group(1) != nil
            let week = group(2) ?? ""
            let id = isSession ? "session"
                : (week.lowercased() == "all models" ? "weekly_all"
                   : "weekly_" + week.lowercased().replacingOccurrences(of: " ", with: "_"))
            guard !windows.contains(where: { $0.id == id }) else { continue }
            let label = isSession ? "Current session" : (week.lowercased() == "all models" ? "All models" : week)
            windows.append(LimitWindow(
                id: id, label: label, usedFraction: percent / 100,
                resetsAt: group(4).flatMap { resetDate(from: $0, now: now) },
                duration: isSession ? ClaudeUsageEstimator.sessionLength : ClaudeUsageEstimator.weekLength,
                fidelity: .official))
        }
        guard windows.contains(where: { $0.id == "session" }) else { throw ParseError.noSessionLine }
        return Reading(windows: windows, plan: plan(in: text))
    }

    /// The plan line `/usage` prints above the windows, e.g. "Plan: Max (20x)".
    static func plan(in text: String) -> String? {
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            for prefix in ["Plan:", "Subscription:"] where line.hasPrefix(prefix) {
                let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : String(value.prefix(40))
            }
        }
        return nil
    }

    /// `Sep 7 at 2:59pm (Asia/Jakarta)` → a date. No year is printed, so the
    /// candidate nearest `now` across last, this and next year is chosen.
    static func resetDate(from text: String, now: Date) -> Date? {
        var stamp = text.trimmingCharacters(in: .whitespaces)
        var zone = TimeZone.current
        if let open = stamp.lastIndex(of: "("), stamp.hasSuffix(")") {
            let name = String(stamp[stamp.index(after: open)...].dropLast())
            zone = TimeZone(identifier: name) ?? zone
            stamp = String(stamp[..<open]).trimmingCharacters(in: .whitespaces)
        }
        stamp = stamp.replacingOccurrences(of: "am", with: "AM").replacingOccurrences(of: "pm", with: "PM")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        let formats = ["MMM d 'at' h:mma", "MMM d 'at' ha", "MMM d, h:mma", "MMM d, ha", "h:mma", "ha"]
        var parsed: Date?
        var timeOnly = false
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: stamp) {
                parsed = date
                timeOnly = !format.contains("MMM")
                break
            }
        }
        guard let parsed else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        if timeOnly {
            // "resets 3pm": the next such time.
            let parts = calendar.dateComponents([.hour, .minute], from: parsed)
            return calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime)
        }
        var parts = calendar.dateComponents([.month, .day, .hour, .minute], from: parsed)
        let year = calendar.component(.year, from: now)
        return [year - 1, year, year + 1].compactMap { candidate -> Date? in
            parts.year = candidate
            return calendar.date(from: parts)
        }.min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }
    }
}
