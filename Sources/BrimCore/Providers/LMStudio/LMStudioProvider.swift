import Foundation

/// One entry from LM Studio's `/api/v0/models`.
struct LMStudioModel: Decodable, Equatable {
    var id: String
    var type: String?
    var state: String?
    var quantization: String?
    var maxContextLength: Int?
    var loadedContextLength: Int?

    enum CodingKeys: String, CodingKey {
        case id, type, state, quantization, max_context_length, loaded_context_length
    }

    init(id: String, type: String? = "llm", state: String? = "loaded", quantization: String? = nil,
         maxContextLength: Int? = nil, loadedContextLength: Int? = nil) {
        self.id = id
        self.type = type
        self.state = state
        self.quantization = quantization
        self.maxContextLength = maxContextLength
        self.loadedContextLength = loadedContextLength
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        state = try? c.decodeIfPresent(String.self, forKey: .state)
        quantization = try? c.decodeIfPresent(String.self, forKey: .quantization)
        maxContextLength = try? c.decodeIfPresent(Int.self, forKey: .max_context_length)
        loadedContextLength = try? c.decodeIfPresent(Int.self, forKey: .loaded_context_length)
    }

    var isLoaded: Bool { state == "loaded" }
    var isEmbedding: Bool { type == "embeddings" }
    var contextLength: Int? { loadedContextLength ?? maxContextLength }
}

enum LMStudioResponse {
    private struct List: Decodable { var data: [LMStudioModel]? }

    static func models(from data: Data) -> [LMStudioModel]? {
        (try? JSONDecoder().decode(List.self, from: data))?.data
    }
}

/// Counts and timings from LM Studio's server log.
///
/// The log records each response in full, text included. This reader walks it
/// line by line and keeps only numbers from inside the `usage` and `stats`
/// blocks of a "Generated prediction" entry; any line that holds a string is
/// skipped without being parsed, so no prompt or reply is ever read out of it.
enum LMStudioServerLog {
    struct Completion: Equatable {
        var model: String
        var at: Date
        var promptTokens: Int?
        var completionTokens: Int?
        var tokensPerSecond: Double?
        var timeToFirstToken: Double?
    }

    struct Summary: Equatable {
        var requests: [String: Int] = [:]
        var completions: [Completion] = []

        func last(for model: String) -> Completion? {
            completions.last { $0.model == model }
        }

        func tokensToday(for model: String) -> Int {
            completions.filter { $0.model == model }
                .reduce(0) { $0 + ($1.promptTokens ?? 0) + ($1.completionTokens ?? 0) }
        }
    }

    private static let header = try! NSRegularExpression(
        pattern: #"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]\[[A-Z]+\](?:\[([^\]]+)\])?\s?(.*)$"#)
    private static let number = try! NSRegularExpression(
        pattern: #"^\s*"([a-z_]+)":\s*(-?[0-9]+(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?),?\s*$"#)

    static func parse(_ lines: [String], timeZone: TimeZone = .current) -> Summary {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var summary = Summary()
        var capture: Completion?
        var block: String?

        func finish() {
            if let done = capture { summary.completions.append(done) }
            capture = nil
            block = nil
        }

        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if let match = header.firstMatch(in: line, range: range) {
                finish()
                guard let stamp = Range(match.range(at: 1), in: line).map({ String(line[$0]) }),
                      let at = formatter.date(from: stamp) else { continue }
                let tag = Range(match.range(at: 2), in: line).map { String(line[$0]) }
                let message = Range(match.range(at: 3), in: line).map { String(line[$0]) } ?? ""
                guard let model = tag, !model.contains("LM STUDIO"), !model.contains("=") else { continue }
                if message.hasPrefix("Running "), message.contains("completion") {
                    summary.requests[model, default: 0] += 1
                } else if message.hasPrefix("Generated prediction: {") {
                    capture = Completion(model: model, at: at)
                }
                continue
            }
            guard capture != nil else { continue }
            if line == "}" { finish(); continue }
            if line.hasPrefix("  \"usage\": {") { block = "usage"; continue }
            if line.hasPrefix("  \"stats\": {") { block = "stats"; continue }
            if line.hasPrefix("  }") { block = nil; continue }
            guard block != nil,
                  let match = number.firstMatch(in: line, range: range),
                  let key = Range(match.range(at: 1), in: line).map({ String(line[$0]) }),
                  let value = Range(match.range(at: 2), in: line).flatMap({ Double(line[$0]) })
            else { continue }
            switch key {
            case "prompt_tokens":        capture?.promptTokens = Int(value)
            case "completion_tokens":    capture?.completionTokens = Int(value)
            case "tokens_per_second":    capture?.tokensPerSecond = value
            case "time_to_first_token":  capture?.timeToFirstToken = value
            default: break
            }
        }
        finish()
        return summary
    }

    /// Today's log file: `server-logs/YYYY-MM/YYYY-MM-DD.N.log`.
    static func todaysFiles(in root: URL, files: LocalFileAccess, now: Date) -> [URL] {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return [] }
        let monthFolder = root.appendingPathComponent(String(format: "%04d-%02d", year, month))
        let prefix = String(format: "%04d-%02d-%02d", year, month, day)
        return files.files(in: monthFolder, withExtension: "log")
            .filter { $0.url.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
            .map(\.url)
    }
}

/// A local LM Studio server, asked over loopback only.
public actor LMStudioProvider: UsageProvider {
    public nonisolated let id = "lmStudio"
    public nonisolated let kind = ProviderKind.lmStudio
    public nonisolated let displayName = "LM Studio"

    private let client: LoopbackHTTPClient
    private let files: LocalFileAccess
    private let logs: URL
    private var settings: LocalRuntimeSettings
    static let allowlist = LoopbackHTTPClient.Allowlist(paths: ["/api/v0/models"])

    public init(environment: ProviderEnvironment, files: LocalFileAccess, settings: LocalRuntimeSettings,
                client: LoopbackHTTPClient = LoopbackHTTPClient()) {
        self.client = client
        self.files = files
        self.logs = environment.lmStudioServerLogs
        self.settings = settings
    }

    public func update(settings: LocalRuntimeSettings) { self.settings = settings }

    public func fetchSnapshot(now: Date) async -> ProviderSnapshot {
        let models: [LMStudioModel]
        do {
            let data = try await client.get(port: settings.port, path: "/api/v0/models", allowlist: Self.allowlist)
            guard let decoded = LMStudioResponse.models(from: data) else {
                return statusSnapshot(.error("LM Studio answered with something Brim could not read."), now: now)
            }
            models = decoded
        } catch LoopbackHTTPClient.RequestError.connectionRefused {
            return statusSnapshot(.unavailable("LM Studio's server isn't running on 127.0.0.1:\(settings.port)."), now: now)
        } catch {
            return statusSnapshot(.unavailable("LM Studio didn't answer on 127.0.0.1:\(settings.port)."), now: now)
        }
        var summary: LMStudioServerLog.Summary?
        if settings.readLogs {
            var lines: [String] = []
            for url in LMStudioServerLog.todaysFiles(in: logs, files: files, now: now) {
                if let tail = try? files.tail(of: url, maxBytes: 4 << 20) {
                    lines += tail.map { String(decoding: $0, as: UTF8.self) }
                }
            }
            summary = LMStudioServerLog.parse(lines)
        }
        return Self.snapshot(id: id, models: models, summary: summary, now: now)
    }

    static func snapshot(id: String, models: [LMStudioModel], summary: LMStudioServerLog.Summary?,
                         now: Date) -> ProviderSnapshot {
        let loaded = models.filter { $0.isLoaded && !$0.isEmbedding }
        var windows: [LimitWindow] = []
        var headline: String?
        for model in loaded {
            var parts: [String] = []
            var fraction: Double?
            let last = summary?.last(for: model.id)
            if let context = model.contextLength {
                if let last, let prompt = last.promptTokens {
                    let used = prompt + (last.completionTokens ?? 0)
                    fraction = Double(used) / Double(context)
                    parts.append("\(CountFormat.compact(used)) of \(CountFormat.compact(context)) ctx")
                } else {
                    parts.append("\(CountFormat.compact(context)) ctx")
                }
            }
            if let speed = last?.tokensPerSecond { parts.append(String(format: "%.0f tok/s", speed)) }
            if let requests = summary?.requests[model.id] { parts.append("\(requests) req today") }
            if let quantization = model.quantization { parts.append(quantization) }
            windows.append(LimitWindow(id: "model.\(model.id)", label: model.id, usedFraction: fraction,
                                       detail: parts.joined(separator: " · "), fidelity: .local,
                                       note: fraction == nil ? nil : "Context used by the last request"))
            if headline == nil, fraction != nil { headline = "model.\(model.id)" }
        }
        if loaded.isEmpty {
            windows.append(LimitWindow(id: "idle", label: "Loaded models", detail: "None", fidelity: .local))
        }
        let label = loaded.isEmpty ? "Idle" : (loaded.count == 1 ? "1 model" : "\(loaded.count) models")
        return ProviderSnapshot(id: id, kind: .lmStudio, displayName: "LM Studio",
                                glyph: ProviderKind.lmStudio.defaultGlyph, fidelity: .local, windows: windows,
                                capturedAt: now, status: .ok,
                                source: "Local runtime on 127.0.0.1 · nothing leaves this Mac",
                                cellLabel: label, preferredHeadlineID: headline)
    }
}
