import Darwin
import Foundation

/// One `~/.claude/sessions/<pid>.json` record, as Claude Code writes it.
struct ClaudeSessionRecord: Equatable {
    let pid: Int32
    let sessionID: String?
    let cwd: String
    let status: String?
    let entrypoint: String?
    /// The generated title. Shown only when the user asks for titles.
    let title: String?
    let waitingFor: String?
    let startedAt: Date?
    let statusChangedAt: Date?

    /// Lenient on purpose: the file belongs to another program and gains
    /// fields on its own schedule. Only pid and cwd are required.
    init?(json data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value,
              let cwd = object["cwd"] as? String
        else { return nil }
        self.pid = pid
        self.cwd = cwd
        sessionID = object["sessionId"] as? String
        status = (object["status"] as? String) ?? (object["tempo"] as? String)
        entrypoint = object["entrypoint"] as? String
        title = object["name"] as? String
        waitingFor = (object["waitingFor"] as? String) ?? (object["needs"] as? String)
        startedAt = (object["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        let changed = (object["statusUpdatedAt"] as? NSNumber) ?? (object["updatedAt"] as? NSNumber)
        statusChangedAt = changed.map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    }

    /// Claude Code's words, mapped onto Brim's. Unknown words read as idle: a
    /// state Brim does not understand is no reason to claim work is happening.
    var state: SessionState {
        switch status?.lowercased() {
        case "busy", "active", "working", "shell": return .busy
        case "waiting", "blocked", "needs_input", "permission": return .waiting
        default: return .idle
        }
    }

    var surface: String {
        switch entrypoint {
        case "claude-desktop", "claude-desktop-3p": return "Desktop"
        case "claude-vscode":                       return "VS Code"
        case "claude-jetbrains":                    return "JetBrains"
        case "sdk-cli", "sdk-ts", "sdk-py":         return "SDK"
        default:                                    return "Terminal"
        }
    }

    var folder: String { (cwd as NSString).lastPathComponent }
}

/// Is a process alive, and is it still the one that wrote the record? Injected
/// so tests can decide.
struct ProcessProbe {
    var isAlive: (Int32) -> Bool
    var startTime: (Int32) -> Date?

    static let system = ProcessProbe(
        isAlive: { pid in
            guard pid > 0 else { return false }
            return kill(pid, 0) == 0 || errno == EPERM
        },
        startTime: { pid in
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
            let started = info.kp_proc.p_starttime
            return Date(timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1e6)
        })
}

/// Reads the session records into `AgentSession`s.
final class ClaudeSessionMonitor {
    /// How long a session shows as finished before settling to idle.
    static let finishedHold: TimeInterval = 8
    /// A working session whose transcript has been silent this long is stale.
    static let quietLimit: TimeInterval = 20 * 60
    /// Slack between the record's start time and the process's, before the
    /// pid is taken to belong to some other program now.
    static let startTolerance: TimeInterval = 120

    private let files: LocalFileAccess
    private let directory: URL
    private let probe: ProcessProbe
    /// Working directories whose sessions are Brim's own `/usage` runs.
    var ignoredDirectories: Set<String> = []
    private var previous: [String: (state: SessionState, since: Date)] = [:]

    init(files: LocalFileAccess, claudeDirectory: URL, probe: ProcessProbe = .system) {
        self.files = files
        self.directory = claudeDirectory.appendingPathComponent("sessions")
        self.probe = probe
    }

    func sessions(now: Date, providerID: String, showTitles: Bool,
                  lastWrite: (String) -> Date?) -> [AgentSession] {
        var result: [AgentSession] = []
        var seen: [String: (state: SessionState, since: Date)] = [:]
        for file in files.files(in: directory, withExtension: "json") {
            guard let data = try? files.contents(of: file.url, maxBytes: 64 << 10),
                  let record = ClaudeSessionRecord(json: data),
                  !ignoredDirectories.contains(record.cwd),
                  isLive(record)
            else { continue }

            let id = "claude.\(record.pid)"
            var state = record.state
            let changedAt = record.statusChangedAt ?? record.startedAt ?? now

            // Leaving busy shows as finished for a moment, so the ring can
            // say "done" before it says "idle".
            let before = previous[id]
            if state == .idle, let before {
                if before.state == .busy {
                    state = .finished
                } else if before.state == .finished, now.timeIntervalSince(before.since) < Self.finishedHold {
                    state = .finished
                }
            }
            if state == .busy {
                let lastSign = max(changedAt, record.sessionID.flatMap(lastWrite) ?? .distantPast)
                if now.timeIntervalSince(lastSign) > Self.quietLimit { state = .stale }
            }

            let since = (before?.state == state) ? before!.since : (state == .finished ? now : changedAt)
            seen[id] = (state, since)

            let name = showTitles ? (record.title?.nonEmpty ?? record.folder) : record.folder
            result.append(AgentSession(
                id: id, providerID: providerID, name: name,
                detail: "\(record.surface) · \(record.folder)", state: state, since: since,
                processID: record.pid, waitingFor: showTitles ? record.waitingFor : nil))
        }
        previous = seen
        return result
    }

    private func isLive(_ record: ClaudeSessionRecord) -> Bool {
        guard probe.isAlive(record.pid) else { return false }
        guard let recorded = record.startedAt, let actual = probe.startTime(record.pid) else { return true }
        return abs(recorded.timeIntervalSince(actual)) < Self.startTolerance
    }
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
