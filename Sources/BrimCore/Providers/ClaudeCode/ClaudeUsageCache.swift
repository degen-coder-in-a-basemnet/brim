import Foundation

/// Anthropic's figure for one window.
struct OfficialWindow: Equatable, Sendable {
    /// 0…1.
    var fraction: Double
    var resetsAt: Date?
}

/// Anthropic's usage figures as of one moment, however Brim came by them.
struct OfficialReading: Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        /// Claude Code's status line, through the handoff file.
        case statusline
        /// Claude Code's own cache in `~/.claude.json`.
        case cache
        /// Brim's opt-in `claude /usage` run.
        case command
        /// Anthropic's usage endpoint, asked by the opt-in keychain fallback.
        case endpoint
    }

    var at: Date
    /// Keyed like Brim's windows: "session", "weekly_all", "weekly_opus", …
    var windows: [String: OfficialWindow]
    var plan: String?
    var origin: Origin
}

/// The usage figures Claude Code caches in `~/.claude.json` each time it asks
/// Anthropic for them (`/usage` does), under `cachedUsageUtilization`.
///
/// That file also holds the account's details and the prompt history of every
/// project, so it is never decoded whole: a byte scan finds the one top-level
/// key and only its value is handed to the decoder. Everything else is stepped
/// over without being turned into a string.
enum ClaudeUsageCache {
    static let key = "cachedUsageUtilization"
    /// Big enough for a config file with years of history in it.
    static let maxBytes = 64 << 20

    static func reading(from data: Data) -> OfficialReading? {
        guard let slice = JSONSlice.topLevelObject(forKey: key, in: data),
              let payload = try? JSONDecoder().decode(Payload.self, from: slice),
              let millis = payload.fetchedAtMs,
              let windows = payload.utilization?.windows, !windows.isEmpty
        else { return nil }
        return OfficialReading(at: Date(timeIntervalSince1970: millis / 1000), windows: windows,
                               plan: nil, origin: .cache)
    }

    /// Anthropic's usage endpoint answers with the same object the cache keeps
    /// under `utilization`.
    static func windows(fromUtilization data: Data) -> [String: OfficialWindow]? {
        guard let utilization = try? JSONDecoder().decode(UtilizationPayload.self, from: data) else { return nil }
        let windows = utilization.windows
        return windows.isEmpty ? nil : windows
    }

    /// Only the fields read; a missing or retyped one is dropped, not fatal.
    private struct Payload: Decodable {
        var fetchedAtMs: Double?
        var utilization: UtilizationPayload?

        enum CodingKeys: String, CodingKey { case fetchedAtMs, utilization }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fetchedAtMs = try? c.decodeIfPresent(Double.self, forKey: .fetchedAtMs)
            utilization = try? c.decodeIfPresent(UtilizationPayload.self, forKey: .utilization)
        }
    }
}

/// Anthropic's usage figures, per window: a whole percentage and a reset time.
struct UtilizationPayload: Decodable {
    var fiveHour: Window?
    var sevenDay: Window?
    var sevenDayOpus: Window?
    var sevenDaySonnet: Window?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour", sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus", sevenDaySonnet = "seven_day_sonnet"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try? c.decodeIfPresent(Window.self, forKey: .fiveHour)
        sevenDay = try? c.decodeIfPresent(Window.self, forKey: .sevenDay)
        sevenDayOpus = try? c.decodeIfPresent(Window.self, forKey: .sevenDayOpus)
        sevenDaySonnet = try? c.decodeIfPresent(Window.self, forKey: .sevenDaySonnet)
    }

    var windows: [String: OfficialWindow] {
        var result: [String: OfficialWindow] = [:]
        let named: [(String, Window?)] = [
            ("session", fiveHour), ("weekly_all", sevenDay), ("weekly_opus", sevenDayOpus), ("weekly_sonnet", sevenDaySonnet),
        ]
        for (id, window) in named {
            guard let window, let percent = window.utilization, percent.isFinite else { continue }
            result[id] = OfficialWindow(fraction: min(max(percent, 0), 100) / 100,
                                        resetsAt: window.resetsAt.flatMap(ClaudeTimestamp.parse))
        }
        return result
    }

    struct Window: Decodable {
        var utilization: Double?
        var resetsAt: String?

        enum CodingKeys: String, CodingKey { case utilization, resetsAt = "resets_at" }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            utilization = try? c.decodeIfPresent(Double.self, forKey: .utilization)
            resetsAt = try? c.decodeIfPresent(String.self, forKey: .resetsAt)
        }
    }
}

/// Cuts one value out of a JSON document without parsing the rest.
enum JSONSlice {
    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")
    private static let colon = UInt8(ascii: ":")
    private static let comma = UInt8(ascii: ",")
    private static let openBrace = UInt8(ascii: "{")
    private static let closeBrace = UInt8(ascii: "}")
    private static let openBracket = UInt8(ascii: "[")
    private static let closeBracket = UInt8(ascii: "]")

    /// The bytes of `key`'s value in the document's outermost object, when that
    /// value is itself an object. A key of the same name deeper down, or the
    /// name quoted inside some string, does not count.
    static func topLevelObject(forKey key: String, in data: Data) -> Data? {
        let needle = Array(key.utf8)
        return data.withUnsafeBytes { raw -> Data? in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            var depth = 0
            var expectingKey = false
            var index = 0
            while index < count {
                let byte = bytes[index]
                if byte == quote {
                    guard let end = endOfString(bytes, openingAt: index) else { return nil }
                    if depth == 1 && expectingKey {
                        expectingKey = false
                        let name = bytes[(index + 1)..<(end - 1)]
                        if name.elementsEqual(needle) {
                            var cursor = skipWhitespace(bytes, from: end)
                            guard cursor < count, bytes[cursor] == colon else { return nil }
                            cursor = skipWhitespace(bytes, from: cursor + 1)
                            guard cursor < count, bytes[cursor] == openBrace,
                                  let close = endOfContainer(bytes, openingAt: cursor)
                            else { return nil }
                            return Data(bytes[cursor..<close])
                        }
                    }
                    index = end
                    continue
                }
                switch byte {
                case openBrace:
                    depth += 1
                    expectingKey = depth == 1
                case openBracket:
                    depth += 1
                case closeBrace, closeBracket:
                    depth -= 1
                case comma:
                    if depth == 1 { expectingKey = true }
                default:
                    break
                }
                index += 1
            }
            return nil
        }
    }

    /// The index just past the string that opens at `start`.
    private static func endOfString(_ bytes: UnsafeBufferPointer<UInt8>, openingAt start: Int) -> Int? {
        var index = start + 1
        while index < bytes.count {
            switch bytes[index] {
            case backslash: index += 2
            case quote: return index + 1
            default: index += 1
            }
        }
        return nil
    }

    /// The index just past the object or array that opens at `start`.
    private static func endOfContainer(_ bytes: UnsafeBufferPointer<UInt8>, openingAt start: Int) -> Int? {
        var depth = 0
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if byte == quote {
                guard let end = endOfString(bytes, openingAt: index) else { return nil }
                index = end
                continue
            }
            if byte == openBrace || byte == openBracket {
                depth += 1
            } else if byte == closeBrace || byte == closeBracket {
                depth -= 1
                if depth == 0 { return index + 1 }
            }
            index += 1
        }
        return nil
    }

    private static func skipWhitespace(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        var index = start
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        return index
    }
}
