import Combine
import Foundation

/// Reads and writes small JSON files in Brim's own Application Support folder,
/// readable by this user only.
public enum PrivateFile {
    public static func prepare(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    public static func write(_ data: Data, to url: URL) throws {
        prepare(directory: url.deletingLastPathComponent())
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }
}

/// The app's preferences, published for the UI and saved on change.
@MainActor
public final class SettingsStore: ObservableObject {
    @Published public private(set) var settings: AppSettings
    public let fileURL: URL
    private var pendingSave: DispatchWorkItem?

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("settings.json")
        if let data = PrivateFile.read(fileURL),
           let decoded = try? JSONDecoder.brim.decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    /// An in-memory store for tests and snapshots; never touches disk.
    public init(settings: AppSettings) {
        self.settings = settings
        fileURL = URL(fileURLWithPath: "/dev/null")
    }

    public func update(_ change: (inout AppSettings) -> Void) {
        var copy = settings
        change(&copy)
        guard copy != settings else { return }
        settings = copy
        scheduleSave()
    }

    private func scheduleSave() {
        guard fileURL.path != "/dev/null" else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    public func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard fileURL.path != "/dev/null", let data = try? JSONEncoder.brim.encode(settings) else { return }
        try? PrivateFile.write(data, to: fileURL)
    }
}

/// What Brim remembers of each provider's last reading, so the notch has
/// something to show at launch. Aggregates only: percentages, reset times and
/// the short text the tooltip printed. Never sessions, never raw responses.
public struct ArchivedReading: Codable, Equatable, Sendable {
    public var id: String
    public var kind: ProviderKind
    public var displayName: String
    public var glyph: ProviderGlyph
    public var fidelity: Fidelity
    public var windows: [LimitWindow]
    public var capturedAt: Date
    public var plan: String?
    public var cellLabel: String?
    public var source: String?
    public var preferredHeadlineID: String?

    public init(_ snapshot: ProviderSnapshot, capturedAt: Date) {
        id = snapshot.id
        kind = snapshot.kind
        displayName = snapshot.displayName
        glyph = snapshot.glyph
        fidelity = snapshot.fidelity
        windows = snapshot.windows
        self.capturedAt = capturedAt
        plan = snapshot.plan
        cellLabel = snapshot.cellLabel
        source = snapshot.source
        preferredHeadlineID = snapshot.preferredHeadlineID
    }

    /// The reading as it is shown at launch: dimmed and dated.
    public var staleSnapshot: ProviderSnapshot {
        ProviderSnapshot(id: id, kind: kind, displayName: displayName, glyph: glyph, fidelity: fidelity,
                         windows: windows, capturedAt: capturedAt, status: .stale(since: capturedAt),
                         source: source, plan: plan, cellLabel: cellLabel, preferredHeadlineID: preferredHeadlineID)
    }
}

public struct ReadingArchive: Codable, Equatable, Sendable {
    public var readings: [String: ArchivedReading] = [:]
    public var claudeCalibration: ClaudeCalibration?

    public init() {}
}

@MainActor
public final class ReadingArchiveStore {
    public let fileURL: URL
    public private(set) var archive: ReadingArchive
    private var pendingSave: DispatchWorkItem?
    private let persists: Bool

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("last-readings.json")
        persists = true
        if let data = PrivateFile.read(fileURL),
           let decoded = try? JSONDecoder.brim.decode(ReadingArchive.self, from: data) {
            archive = decoded
        } else {
            archive = ReadingArchive()
        }
    }

    public init(inMemory archive: ReadingArchive = ReadingArchive()) {
        fileURL = URL(fileURLWithPath: "/dev/null")
        persists = false
        self.archive = archive
    }

    public func remember(_ snapshot: ProviderSnapshot) {
        // Only readings worth showing again: a status with no numbers is
        // re-derived at the next launch anyway.
        guard snapshot.status == .ok, !snapshot.windows.isEmpty, snapshot.kind != .demo else { return }
        archive.readings[snapshot.id] = ArchivedReading(snapshot, capturedAt: snapshot.capturedAt ?? Date())
        scheduleSave()
    }

    public func forget(_ id: String) {
        guard archive.readings.removeValue(forKey: id) != nil else { return }
        scheduleSave()
    }

    public func clear() {
        pendingSave?.cancel()
        pendingSave = nil
        archive = ReadingArchive()
        if persists { try? FileManager.default.removeItem(at: fileURL) }
    }

    public func setCalibration(_ calibration: ClaudeCalibration) {
        guard archive.claudeCalibration != calibration else { return }
        archive.claudeCalibration = calibration
        scheduleSave()
    }

    private func scheduleSave() {
        guard persists else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    public func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard persists, let data = try? JSONEncoder.brim.encode(archive) else { return }
        try? PrivateFile.write(data, to: fileURL)
    }
}

extension JSONEncoder {
    static var brim: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var brim: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
