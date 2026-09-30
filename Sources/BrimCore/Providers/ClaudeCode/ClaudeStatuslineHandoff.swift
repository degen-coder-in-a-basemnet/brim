import Foundation

/// Anthropic's figures as Claude Code last handed them to its status line.
///
/// After every response Claude Code passes `rate_limits` to the status-line
/// command: the freshest official numbers there are, but never saved anywhere.
/// A few lines in that command write just the percentages and reset times to
/// `claude-statusline.json` in Brim's folder, and this reads them back.
public enum ClaudeStatuslineHandoff {
    static let fileName = "claude-statusline.json"
    static let maxBytes = 64 << 10

    static func url(in applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(fileName)
    }

    static func reading(from data: Data) -> OfficialReading? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let updated = payload.updatedAt, updated.isFinite, updated > 0
        else { return nil }
        var windows: [String: OfficialWindow] = [:]
        let named: [(String, Window?)] = [
            ("session", payload.fiveHour),
            ("weekly_all", payload.sevenDay),
            ("weekly_opus", payload.sevenDayOpus),
            ("weekly_sonnet", payload.sevenDaySonnet),
        ]
        for (id, window) in named {
            guard let window, let percent = window.usedPercentage, percent.isFinite else { continue }
            windows[id] = OfficialWindow(fraction: min(max(percent, 0), 100) / 100, resetsAt: window.resetsAt)
        }
        guard !windows.isEmpty else { return nil }
        return OfficialReading(at: Date(timeIntervalSince1970: updated), windows: windows, plan: nil, origin: .statusline)
    }

    private struct Payload: Decodable {
        var updatedAt: Double?
        var fiveHour: Window?
        var sevenDay: Window?
        var sevenDayOpus: Window?
        var sevenDaySonnet: Window?

        enum CodingKeys: String, CodingKey {
            case updatedAt = "updated_at", fiveHour = "five_hour", sevenDay = "seven_day"
            case sevenDayOpus = "seven_day_opus", sevenDaySonnet = "seven_day_sonnet"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            updatedAt = try? c.decodeIfPresent(Double.self, forKey: .updatedAt)
            fiveHour = try? c.decodeIfPresent(Window.self, forKey: .fiveHour)
            sevenDay = try? c.decodeIfPresent(Window.self, forKey: .sevenDay)
            sevenDayOpus = try? c.decodeIfPresent(Window.self, forKey: .sevenDayOpus)
            sevenDaySonnet = try? c.decodeIfPresent(Window.self, forKey: .sevenDaySonnet)
        }
    }

    private struct Window: Decodable {
        var usedPercentage: Double?
        var resetsAt: Date?

        enum CodingKeys: String, CodingKey { case usedPercentage = "used_percentage", resetsAt = "resets_at" }

        /// Claude Code hands over epoch seconds; an ISO date is accepted too.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            usedPercentage = try? c.decodeIfPresent(Double.self, forKey: .usedPercentage)
            if let seconds = try? c.decodeIfPresent(Double.self, forKey: .resetsAt), seconds.isFinite, seconds > 0 {
                resetsAt = Date(timeIntervalSince1970: seconds)
            } else if let text = try? c.decodeIfPresent(String.self, forKey: .resetsAt) {
                resetsAt = ClaudeTimestamp.parse(text)
            }
        }
    }

    /// The lines to add to a status-line command written in JavaScript. Call
    /// `writeBrimHandoff(data)` with the parsed status-line JSON.
    public static let nodeSnippet = """
    // Brim: hands Anthropic's rate limits from Claude Code's status line to the
    // Brim notch. Writes only percentages and reset times, only if Brim is
    // installed, and never throws.
    function writeBrimHandoff(data) {
      try {
        const limits = data && data.rate_limits;
        if (!limits) return;
        const fs = require('fs'), path = require('path'), os = require('os');
        const dir = path.join(os.homedir(), 'Library', 'Application Support', 'Brim');
        if (!fs.existsSync(dir)) return;
        const pick = (w) => (w && typeof w.used_percentage === 'number')
          ? { used_percentage: w.used_percentage, resets_at: w.resets_at } : undefined;
        const out = { version: 1, updated_at: Date.now() / 1000,
          five_hour: pick(limits.five_hour), seven_day: pick(limits.seven_day) };
        if (!out.five_hour && !out.seven_day) return;
        const file = path.join(dir, 'claude-statusline.json');
        const tmp = `${file}.${process.pid}.tmp`;
        fs.writeFileSync(tmp, JSON.stringify(out), { mode: 0o600 });
        fs.renameSync(tmp, file);
      } catch (_) {}
    }
    """
}
