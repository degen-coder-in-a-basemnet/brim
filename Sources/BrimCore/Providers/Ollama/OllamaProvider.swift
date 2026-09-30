import Foundation

/// What `/api/ps` says about one loaded model.
struct OllamaLoadedModel: Decodable, Equatable {
    var name: String
    var size: Int64?
    var sizeVRAM: Int64?
    var expiresAt: Date?
    var contextLength: Int?
    var parameterSize: String?
    var quantization: String?

    enum CodingKeys: String, CodingKey {
        case name, model, size, size_vram, expires_at, context_length, details
    }
    enum DetailKeys: String, CodingKey { case parameter_size, quantization_level }

    init(name: String, size: Int64? = nil, sizeVRAM: Int64? = nil, expiresAt: Date? = nil,
         contextLength: Int? = nil, parameterSize: String? = nil, quantization: String? = nil) {
        self.name = name
        self.size = size
        self.sizeVRAM = sizeVRAM
        self.expiresAt = expiresAt
        self.contextLength = contextLength
        self.parameterSize = parameterSize
        self.quantization = quantization
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? (try? c.decode(String.self, forKey: .model)) ?? "model"
        size = try? c.decodeIfPresent(Int64.self, forKey: .size)
        sizeVRAM = try? c.decodeIfPresent(Int64.self, forKey: .size_vram)
        expiresAt = (try? c.decodeIfPresent(String.self, forKey: .expires_at)).flatMap { $0 }.flatMap(OllamaDates.parse)
        contextLength = try? c.decodeIfPresent(Int.self, forKey: .context_length)
        if let details = try? c.nestedContainer(keyedBy: DetailKeys.self, forKey: .details) {
            parameterSize = try? details.decodeIfPresent(String.self, forKey: .parameter_size)
            quantization = try? details.decodeIfPresent(String.self, forKey: .quantization_level)
        }
    }
}

enum OllamaDates {
    /// Go writes RFC 3339 with nanoseconds and an offset.
    static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        // Nanosecond precision is more than ISO8601DateFormatter accepts.
        if let dot = text.firstIndex(of: "."),
           let zone = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let trimmed = String(text[..<dot]) + String(text[dot...].prefix(4)) + String(text[zone...])
            return formatter.date(from: trimmed)
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

enum OllamaResponse {
    private struct PS: Decodable { var models: [OllamaLoadedModel]? }

    static func loadedModels(from data: Data) -> [OllamaLoadedModel]? {
        (try? JSONDecoder().decode(PS.self, from: data))?.models
    }
}

/// Request counts and timings from Ollama's server log — the access-log lines
/// only, which carry a status, a duration and a path, and never a body.
enum OllamaServerLog {
    struct Request: Equatable {
        var at: Date
        var status: Int
        var duration: TimeInterval
        var path: String
    }

    private static let line = try! NSRegularExpression(
        pattern: #"^\[GIN\]\s+(\d{4}/\d{2}/\d{2}\s+-\s+\d{2}:\d{2}:\d{2})\s+\|\s+(\d{3})\s+\|\s+([0-9.µunmsh]+)\s+\|\s+[^|]+\|\s+(GET|POST|DELETE|HEAD|PUT)\s+"([^"?]+)"#)

    static let inferencePaths: Set<String> = [
        "/api/chat", "/api/generate", "/api/embed", "/api/embeddings",
        "/v1/chat/completions", "/v1/completions", "/v1/embeddings", "/v1/responses",
    ]

    static func parse(_ text: String, timeZone: TimeZone = .current) -> Request? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = line.firstMatch(in: text, range: range),
              let stamp = Range(match.range(at: 1), in: text).map({ String(text[$0]) }),
              let status = Range(match.range(at: 2), in: text).flatMap({ Int(text[$0]) }),
              let duration = Range(match.range(at: 3), in: text).flatMap({ goDuration(String(text[$0])) }),
              let path = Range(match.range(at: 5), in: text).map({ String(text[$0]) })
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy/MM/dd - HH:mm:ss"
        let compact = stamp.replacingOccurrences(of: #"\s+-\s+"#, with: " - ", options: .regularExpression)
        guard let at = formatter.date(from: compact) else { return nil }
        return Request(at: at, status: status, duration: duration, path: path)
    }

    /// Go's `time.Duration` text: "850µs", "12.5ms", "3.2s", "1m4.5s", "1h2m3s".
    static func goDuration(_ text: String) -> TimeInterval? {
        let units: [(String, Double)] = [("h", 3600), ("ms", 0.001), ("µs", 1e-6), ("us", 1e-6), ("ns", 1e-9), ("m", 60), ("s", 1)]
        var rest = Substring(text)
        var total = 0.0
        var matchedAny = false
        while !rest.isEmpty {
            let number = rest.prefix { $0.isNumber || $0 == "." }
            guard !number.isEmpty, let value = Double(number) else { return nil }
            rest = rest.dropFirst(number.count)
            guard let unit = units.first(where: { rest.hasPrefix($0.0) }) else { return nil }
            total += value * unit.1
            rest = rest.dropFirst(unit.0.count)
            matchedAny = true
        }
        return matchedAny ? total : nil
    }
}

/// A local Ollama server, asked over loopback only.
public actor OllamaProvider: UsageProvider {
    public nonisolated let id = "ollama"
    public nonisolated let kind = ProviderKind.ollama
    public nonisolated let displayName = "Ollama"

    private let client: LoopbackHTTPClient
    private let files: LocalFileAccess
    private let logURL: URL
    private var settings: LocalRuntimeSettings
    private var requestsCache: (day: Date, offset: UInt64, requests: [OllamaServerLog.Request])?
    static let allowlist = LoopbackHTTPClient.Allowlist(paths: ["/api/ps", "/api/version"])

    public init(environment: ProviderEnvironment, files: LocalFileAccess, settings: LocalRuntimeSettings,
                client: LoopbackHTTPClient = LoopbackHTTPClient()) {
        self.client = client
        self.files = files
        self.logURL = environment.ollamaLogs.appendingPathComponent("server.log")
        self.settings = settings
    }

    public func update(settings: LocalRuntimeSettings) { self.settings = settings }

    public func fetchSnapshot(now: Date) async -> ProviderSnapshot {
        let models: [OllamaLoadedModel]
        do {
            let data = try await client.get(port: settings.port, path: "/api/ps", allowlist: Self.allowlist)
            guard let decoded = OllamaResponse.loadedModels(from: data) else {
                return statusSnapshot(.error("Ollama answered with something Brim could not read."), now: now)
            }
            models = decoded
        } catch LoopbackHTTPClient.RequestError.connectionRefused {
            return statusSnapshot(.unavailable("Ollama isn't running on 127.0.0.1:\(settings.port)."), now: now)
        } catch {
            return statusSnapshot(.unavailable("Ollama didn't answer on 127.0.0.1:\(settings.port)."), now: now)
        }
        let requests = settings.readLogs ? todaysRequests(now: now) : nil
        return Self.snapshot(id: id, models: models, requests: requests, now: now,
                             physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }

    static func snapshot(id: String, models: [OllamaLoadedModel], requests: [OllamaServerLog.Request]?,
                         now: Date, physicalMemory: UInt64) -> ProviderSnapshot {
        var windows: [LimitWindow] = []
        let resident = models.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        if !models.isEmpty, physicalMemory > 0 {
            windows.append(LimitWindow(
                id: "memory", label: "Memory in use by models",
                usedFraction: Double(resident) / Double(physicalMemory),
                detail: "\(CountFormat.bytes(resident)) of \(CountFormat.bytes(Int64(physicalMemory)))",
                fidelity: .local))
        }
        for model in models {
            var parts: [String] = []
            if let size = model.size { parts.append(CountFormat.bytes(size)) }
            if let size = model.size, size > 0, let vram = model.sizeVRAM {
                parts.append("\(Percent.value(for: Double(vram) / Double(size)))% GPU")
            }
            if let context = model.contextLength { parts.append("\(CountFormat.compact(context)) ctx") }
            if let expires = model.expiresAt, expires > now {
                parts.append("unloads in \(ElapsedCopy.duration(since: now, now: expires))")
            }
            windows.append(LimitWindow(id: "model.\(model.name)", label: model.name,
                                       detail: parts.joined(separator: " · "), fidelity: .local))
        }
        if let requests {
            let inference = requests.filter { OllamaServerLog.inferencePaths.contains($0.path) }
            if !inference.isEmpty {
                let average = inference.map(\.duration).reduce(0, +) / Double(inference.count)
                windows.append(LimitWindow(id: "requests", label: "Requests today",
                                           detail: "\(inference.count) · avg \(String(format: "%.1f", average))s",
                                           fidelity: .local))
            }
        }
        if models.isEmpty {
            windows.insert(LimitWindow(id: "idle", label: "Loaded models", detail: "None", fidelity: .local), at: 0)
        }
        let label = models.isEmpty ? "Idle" : (models.count == 1 ? "1 model" : "\(models.count) models")
        return ProviderSnapshot(id: id, kind: .ollama, displayName: "Ollama", glyph: ProviderKind.ollama.defaultGlyph,
                                fidelity: .local, windows: windows, capturedAt: now, status: .ok,
                                source: "Local runtime on 127.0.0.1 · nothing leaves this Mac",
                                cellLabel: label, preferredHeadlineID: "memory")
    }

    /// Today's access-log lines, read incrementally.
    private func todaysRequests(now: Date) -> [OllamaServerLog.Request]? {
        guard files.exists(logURL) else { return nil }
        let today = Calendar.current.startOfDay(for: now)
        var cache = requestsCache
        if cache?.day != today { cache = (today, 0, []) }
        guard var current = cache,
              let (lines, next) = try? files.lines(of: logURL, from: current.offset) else { return cache?.requests }
        for data in lines {
            let text = String(decoding: data.prefix(400), as: UTF8.self)
            guard text.hasPrefix("[GIN]"), let request = OllamaServerLog.parse(text), request.at >= today else { continue }
            current.requests.append(request)
        }
        current.offset = next
        requestsCache = current
        return current.requests
    }
}
