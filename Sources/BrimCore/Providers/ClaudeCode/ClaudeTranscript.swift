import Foundation

/// Token counts from one API response, as Claude Code logged them.
struct TokenCounts: Equatable, Sendable {
    var input: Int = 0
    var output: Int = 0
    var cacheCreation: Int = 0
    var cacheRead: Int = 0

    var total: Int { input + output + cacheCreation + cacheRead }

    /// Input-token equivalents, weighted the way Anthropic prices them: output
    /// five times input, cache writes a quarter more, cache reads a tenth.
    /// Cache reads dominate raw totals, so counting them at face value would
    /// make a long cached session look far heavier than it is.
    var weighted: Double {
        Double(input) + Double(output) * 5 + Double(cacheCreation) * 1.25 + Double(cacheRead) * 0.1
    }

    static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(input: a.input + b.input, output: a.output + b.output,
                    cacheCreation: a.cacheCreation + b.cacheCreation, cacheRead: a.cacheRead + b.cacheRead)
    }

    /// Field-wise maximum: Claude Code can log one response on several lines,
    /// each repeating the usage, and a later line may carry the final count.
    func merged(with other: TokenCounts) -> TokenCounts {
        TokenCounts(input: max(input, other.input), output: max(output, other.output),
                    cacheCreation: max(cacheCreation, other.cacheCreation),
                    cacheRead: max(cacheRead, other.cacheRead))
    }
}

struct UsageEvent: Equatable, Sendable {
    /// Message id and request id: one API response, however many lines it took.
    let key: String
    let timestamp: Date
    let model: String?
    var tokens: TokenCounts
}

/// A rate-limit rejection Claude Code recorded. Anthropic's own verdict, so the
/// most trustworthy thing in these logs: this window was spent, until then.
struct LimitEvent: Equatable, Sendable {
    let timestamp: Date
    /// "five_hour", "seven_day", "seven_day_opus", …
    let type: String
    let resetsAt: Date
    /// "rejected" when the request was refused.
    let status: String
}

enum ClaudeLogEntry: Equatable {
    case usage(UsageEvent)
    case limit(LimitEvent)
}

/// Reads one JSONL line down to the handful of fields Brim needs.
///
/// The decoder is given a struct that names only those fields, so message
/// content is skipped rather than turned into strings, and nothing from it is
/// kept. Lines that mention neither usage nor a quota are rejected before any
/// decoding at all.
enum ClaudeTranscriptParser {
    private static let usageMarker = Data(#""usage""#.utf8)
    private static let quotaMarker = Data(#""quotaLimits""#.utf8)

    static func mightMatter(_ line: Data) -> Bool {
        line.range(of: usageMarker) != nil || line.range(of: quotaMarker) != nil
    }

    static func parse(_ line: Data) -> ClaudeLogEntry? {
        guard mightMatter(line),
              let record = try? JSONDecoder().decode(Record.self, from: line),
              let stamp = record.timestamp,
              let timestamp = ClaudeTimestamp.parse(stamp)
        else { return nil }

        if let quota = record.quotaLimits, let type = quota.rateLimitType, let resets = quota.resetsAt {
            return .limit(LimitEvent(timestamp: timestamp, type: type,
                                     resetsAt: Date(timeIntervalSince1970: resets),
                                     status: quota.status ?? "rejected"))
        }

        guard record.type == "assistant", let message = record.message, let usage = message.usage else {
            return nil
        }
        let tokens = TokenCounts(input: usage.input_tokens ?? 0, output: usage.output_tokens ?? 0,
                                 cacheCreation: usage.cache_creation_input_tokens ?? 0,
                                 cacheRead: usage.cache_read_input_tokens ?? 0)
        guard tokens.total > 0 else { return nil }
        let key = "\(message.id ?? "")|\(record.requestId ?? stamp)"
        return .usage(UsageEvent(key: key, timestamp: timestamp, model: message.model, tokens: tokens))
    }

    /// Only the fields read. Every one is optional and decoded leniently: the
    /// file is written by another program on its own release schedule.
    private struct Record: Decodable {
        var type: String?
        var timestamp: String?
        var requestId: String?
        var message: Message?
        var quotaLimits: Quota?

        enum CodingKeys: String, CodingKey { case type, timestamp, requestId, message, quotaLimits }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            timestamp = try? c.decodeIfPresent(String.self, forKey: .timestamp)
            requestId = try? c.decodeIfPresent(String.self, forKey: .requestId)
            message = try? c.decodeIfPresent(Message.self, forKey: .message)
            quotaLimits = try? c.decodeIfPresent(Quota.self, forKey: .quotaLimits)
        }
    }

    private struct Message: Decodable {
        var id: String?
        var model: String?
        var usage: Usage?

        enum CodingKeys: String, CodingKey { case id, model, usage }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try? c.decodeIfPresent(String.self, forKey: .id)
            model = try? c.decodeIfPresent(String.self, forKey: .model)
            usage = try? c.decodeIfPresent(Usage.self, forKey: .usage)
        }
    }

    private struct Usage: Decodable {
        var input_tokens: Int?
        var output_tokens: Int?
        var cache_creation_input_tokens: Int?
        var cache_read_input_tokens: Int?
    }

    private struct Quota: Decodable {
        var status: String?
        var resetsAt: Double?
        var rateLimitType: String?
    }
}

/// Claude Code writes ISO 8601 timestamps with milliseconds and a `Z`; the
/// usage cache relays Anthropic's, with microseconds and a `+00:00` offset.
enum ClaudeTimestamp {
    private static let longFraction = try! NSRegularExpression(pattern: #"(\.\d{3})\d+"#)

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ text: String) -> Date? {
        if let date = fractional.date(from: text) ?? whole.date(from: text) { return date }
        // The formatter reads at most milliseconds.
        let range = NSRange(text.startIndex..., in: text)
        let trimmed = longFraction.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
        return trimmed == text ? nil : fractional.date(from: trimmed)
    }
}
