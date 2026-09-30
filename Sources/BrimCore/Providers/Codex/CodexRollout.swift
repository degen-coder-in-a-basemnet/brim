import Foundation

/// The rate-limit figures Codex's server attached to a response, as Codex wrote
/// them into its session log.
struct CodexRateLimits: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        var usedPercent: Double
        var windowMinutes: Int?
        var resetsAt: Date?
    }

    var timestamp: Date
    var primary: Window?
    var secondary: Window?
    var planType: String?
}

enum CodexLogEntry: Equatable {
    case rateLimits(CodexRateLimits)
    /// A turn starting, finishing, or stopping to ask for approval.
    case activity(kind: String, timestamp: Date)
    case sessionMeta(cwd: String?, originator: String?)
}

/// Reads one rollout line down to the fields Brim uses. Message text, tool
/// output and instructions are never decoded.
enum CodexRolloutParser {
    static let activityKinds: Set<String> = [
        "task_started", "task_complete", "turn_aborted",
        "exec_approval_request", "apply_patch_approval_request", "request_user_input",
    ]

    private static let markers: [Data] = [
        #""rate_limits""#, #""task_started""#, #""task_complete""#, #""turn_aborted""#,
        #""session_meta""#, #"_approval_request""#, #""request_user_input""#,
    ].map { Data($0.utf8) }

    static func mightMatter(_ line: Data) -> Bool {
        markers.contains { line.range(of: $0) != nil }
    }

    static func parse(_ line: Data) -> CodexLogEntry? {
        guard mightMatter(line),
              let record = try? JSONDecoder().decode(Record.self, from: line),
              let stamp = record.timestamp, let timestamp = ClaudeTimestamp.parse(stamp)
        else { return nil }

        if record.type == "session_meta" {
            return .sessionMeta(cwd: record.payload?.cwd, originator: record.payload?.originator)
        }
        guard record.type == "event_msg", let payload = record.payload, let kind = payload.type else { return nil }
        if kind == "token_count", let limits = payload.rate_limits {
            func window(_ raw: RawWindow?) -> CodexRateLimits.Window? {
                guard let raw, let used = raw.used_percent else { return nil }
                var resets = raw.resets_at.map { Date(timeIntervalSince1970: $0) }
                if resets == nil, let seconds = raw.resets_in_seconds {
                    resets = timestamp.addingTimeInterval(seconds)
                }
                return .init(usedPercent: used, windowMinutes: raw.window_minutes, resetsAt: resets)
            }
            let parsed = CodexRateLimits(timestamp: timestamp, primary: window(limits.primary),
                                         secondary: window(limits.secondary), planType: limits.plan_type)
            guard parsed.primary != nil || parsed.secondary != nil else { return nil }
            return .rateLimits(parsed)
        }
        if activityKinds.contains(kind) {
            return .activity(kind: kind, timestamp: timestamp)
        }
        return nil
    }

    private struct Record: Decodable {
        var type: String?
        var timestamp: String?
        var payload: Payload?

        enum CodingKeys: String, CodingKey { case type, timestamp, payload }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            timestamp = try? c.decodeIfPresent(String.self, forKey: .timestamp)
            payload = try? c.decodeIfPresent(Payload.self, forKey: .payload)
        }
    }

    private struct Payload: Decodable {
        var type: String?
        var cwd: String?
        var originator: String?
        var rate_limits: RawLimits?

        enum CodingKeys: String, CodingKey { case type, cwd, originator, rate_limits }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
            originator = try? c.decodeIfPresent(String.self, forKey: .originator)
            rate_limits = try? c.decodeIfPresent(RawLimits.self, forKey: .rate_limits)
        }
    }

    private struct RawLimits: Decodable {
        var primary: RawWindow?
        var secondary: RawWindow?
        var plan_type: String?
    }

    private struct RawWindow: Decodable {
        var used_percent: Double?
        var window_minutes: Int?
        var resets_at: Double?
        var resets_in_seconds: Double?
    }
}

/// Follows Codex's session logs incrementally, like the Claude scanner.
final class CodexRolloutScanner {
    static let lookback: TimeInterval = 8 * 86_400

    struct SessionTrace: Equatable {
        var cwd: String?
        var originator: String?
        var lastActivity: (kind: String, at: Date)?
        var modified: Date

        static func == (a: SessionTrace, b: SessionTrace) -> Bool {
            a.cwd == b.cwd && a.originator == b.originator && a.modified == b.modified
                && a.lastActivity?.kind == b.lastActivity?.kind && a.lastActivity?.at == b.lastActivity?.at
        }
    }

    private let files: LocalFileAccess
    private let root: URL
    private var offsets: [URL: UInt64] = [:]
    private(set) var latestLimits: CodexRateLimits?
    private(set) var traces: [String: SessionTrace] = [:]

    init(files: LocalFileAccess, codexDirectory: URL) {
        self.files = files
        self.root = codexDirectory.appendingPathComponent("sessions")
    }

    var hasSessions: Bool { files.exists(root) }

    func scan(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.lookback)
        let candidates = files.filesRecursively(in: root, withExtension: "jsonl", modifiedAfter: cutoff)
        for file in candidates {
            let key = file.url.deletingPathExtension().lastPathComponent
            var trace = traces[key] ?? SessionTrace(modified: file.modified)
            trace.modified = file.modified
            let start = offsets[file.url] ?? 0
            if start == 0 || UInt64(file.size) != start,
               let (lines, next) = try? files.lines(of: file.url, from: start) {
                offsets[file.url] = next
                for line in lines {
                    switch CodexRolloutParser.parse(line) {
                    case .rateLimits(let limits):
                        if limits.timestamp >= (latestLimits?.timestamp ?? .distantPast) { latestLimits = limits }
                    case .activity(let kind, let at):
                        if at >= (trace.lastActivity?.at ?? .distantPast) { trace.lastActivity = (kind, at) }
                    case .sessionMeta(let cwd, let originator):
                        trace.cwd = trace.cwd ?? cwd
                        trace.originator = trace.originator ?? originator
                    case nil:
                        break
                    }
                }
            }
            traces[key] = trace
        }
        let live = Set(candidates.map(\.url))
        offsets = offsets.filter { live.contains($0.key) }
        let liveKeys = Set(candidates.map { $0.url.deletingPathExtension().lastPathComponent })
        traces = traces.filter { liveKeys.contains($0.key) }
    }
}
