import Foundation

/// Follows every Claude Code transcript modified in the lookback period,
/// reading only the bytes appended since the last pass.
///
/// The first pass reads the last eight days of logs; after that each pass costs
/// a directory walk and whatever was written since. Offsets are held in memory
/// only — nothing about the logs is written to disk.
final class ClaudeTranscriptScanner {
    static let lookback: TimeInterval = 8 * 86_400

    private let files: LocalFileAccess
    private let projects: URL
    /// How much of a file is read at once. A pass keeps reading until the file
    /// is exhausted: a calibration taken from half a log would be wrong.
    private let chunkBytes: Int
    private var offsets: [URL: UInt64] = [:]
    /// Last write per transcript, keyed by session id (the file's name).
    private(set) var transcriptModified: [String: Date] = [:]
    let ledger = ClaudeUsageLedger()
    /// The earliest moment the ledger is complete from.
    private(set) var coverageStart: Date = .distantFuture

    init(files: LocalFileAccess, claudeDirectory: URL, chunkBytes: Int = 32 << 20) {
        self.files = files
        self.projects = claudeDirectory.appendingPathComponent("projects")
        self.chunkBytes = chunkBytes
    }

    var hasProjects: Bool { files.exists(projects) }

    /// Reads everything new. Returns the number of lines that mattered.
    @discardableResult
    func scan(now: Date) -> Int {
        let cutoff = now.addingTimeInterval(-Self.lookback)
        if coverageStart == .distantFuture { coverageStart = cutoff }
        let candidates = files.filesRecursively(in: projects, withExtension: "jsonl", modifiedAfter: cutoff)
        var matched = 0
        var modified: [String: Date] = [:]
        for file in candidates {
            let stem = file.url.deletingPathExtension().lastPathComponent
            modified[stem] = max(modified[stem] ?? .distantPast, file.modified)
            var start = offsets[file.url] ?? 0
            if start > 0 && UInt64(file.size) == start { continue }
            while let (lines, next) = try? files.lines(of: file.url, from: start, maxBytes: chunkBytes) {
                offsets[file.url] = next
                for line in lines {
                    guard let entry = ClaudeTranscriptParser.parse(line) else { continue }
                    ledger.ingest(entry)
                    matched += 1
                }
                // Done once a read makes no progress or reaches what was listed.
                guard next > start, next < UInt64(file.size) else { break }
                start = next
            }
        }
        // Forget files that aged out, and events older than the lookback.
        transcriptModified = modified
        let live = Set(candidates.map(\.url))
        offsets = offsets.filter { live.contains($0.key) }
        ledger.prune(before: cutoff)
        coverageStart = max(coverageStart, cutoff)
        return matched
    }

    /// When the transcript for a session last changed, as of the last scan.
    func lastWrite(sessionID: String) -> Date? {
        transcriptModified[sessionID]
    }
}
