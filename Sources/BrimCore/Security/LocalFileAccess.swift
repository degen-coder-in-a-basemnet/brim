import Foundation

/// The only way adapters read files.
///
/// Every read is checked against a fixed list of roots — the folders Brim
/// documents in PRIVACY.md — after symlinks are resolved, so a stray path or a
/// link cannot walk an adapter into the keychain or anywhere else. Reads are
/// bounded, and file contents never leave the adapter that asked for them.
public struct LocalFileAccess: Sendable {
    public enum AccessError: Error, Equatable {
        case outsideAllowedRoots
        case unreadable
        case tooLarge
    }

    public let allowedRoots: [URL]

    public init(allowedRoots: [URL]) {
        self.allowedRoots = allowedRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    /// The roots the shipping adapters need, and nothing else.
    public static func standard(_ environment: ProviderEnvironment) -> LocalFileAccess {
        LocalFileAccess(allowedRoots: [
            environment.claudeDirectory.appendingPathComponent("projects"),
            environment.claudeDirectory.appendingPathComponent("sessions"),
            environment.claudeConfigFile,
            environment.codexDirectory.appendingPathComponent("sessions"),
            environment.ollamaLogs,
            environment.lmStudioServerLogs,
            environment.applicationSupport,
        ])
    }

    public func isAllowed(_ url: URL) -> Bool {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        return allowedRoots.contains { root in
            resolved == root.path || resolved.hasPrefix(root.path + "/")
        }
    }

    private func check(_ url: URL) throws {
        guard isAllowed(url) else { throw AccessError.outsideAllowedRoots }
    }

    public func exists(_ url: URL) -> Bool {
        isAllowed(url) && FileManager.default.fileExists(atPath: url.path)
    }

    /// Regular files directly inside `directory` (no recursion), with their
    /// modification dates and sizes.
    public func files(in directory: URL, withExtension ext: String? = nil) -> [FileInfo] {
        guard isAllowed(directory),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        return names.compactMap { name in
            if let ext, !name.hasSuffix(".\(ext)") { return nil }
            return info(for: directory.appendingPathComponent(name))
        }
    }

    /// Regular files anywhere under `directory`, skipping anything not allowed.
    public func filesRecursively(in directory: URL, withExtension ext: String,
                                 modifiedAfter cutoff: Date? = nil) -> [FileInfo] {
        guard isAllowed(directory),
              let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var result: [FileInfo] = []
        for case let url as URL in enumerator where url.pathExtension == ext {
            guard let item = info(for: url) else { continue }
            if let cutoff, item.modified < cutoff { continue }
            result.append(item)
        }
        return result
    }

    public func info(for url: URL) -> FileInfo? {
        guard isAllowed(url),
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true
        else { return nil }
        return FileInfo(url: url, modified: values.contentModificationDate ?? .distantPast,
                        size: Int64(values.fileSize ?? 0))
    }

    /// A whole small file. Refuses anything over `maxBytes`.
    public func contents(of url: URL, maxBytes: Int = 1 << 20) throws -> Data {
        try check(url)
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw AccessError.unreadable }
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw AccessError.tooLarge }
        return data
    }

    /// Complete lines appended since `offset`, and the offset to resume from.
    ///
    /// A trailing partial line — one the writer has not finished — is left for
    /// the next call rather than parsed half-written. At most `maxBytes` are
    /// read per call, so a huge log is consumed over several polls.
    public func lines(of url: URL, from offset: UInt64, maxBytes: Int = 32 << 20) throws -> (lines: [Data], next: UInt64) {
        try check(url)
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw AccessError.unreadable }
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        // The file shrank: it was rewritten, so start again from the top.
        let start = offset > end ? 0 : offset
        try handle.seek(toOffset: start)
        let data = try handle.read(upToCount: maxBytes) ?? Data()
        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            // No complete line yet. If the read was capped, the line is longer
            // than the cap: skip it instead of stalling on it for ever.
            return ([], data.count >= maxBytes ? start + UInt64(data.count) : start)
        }
        let complete = data[data.startIndex...lastNewline]
        let lines = complete.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
        return (lines, start + UInt64(complete.count))
    }

    /// The last `maxBytes` of a file, starting at a line boundary.
    public func tail(of url: URL, maxBytes: Int = 256 << 10) throws -> [Data] {
        try check(url)
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw AccessError.unreadable }
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        try handle.seek(toOffset: start)
        var data = try handle.read(upToCount: maxBytes) ?? Data()
        if start > 0, let firstNewline = data.firstIndex(of: 0x0A) {
            data = data[data.index(after: firstNewline)...]
        }
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
    }
}

public struct FileInfo: Equatable, Sendable {
    public let url: URL
    public let modified: Date
    public let size: Int64
}
