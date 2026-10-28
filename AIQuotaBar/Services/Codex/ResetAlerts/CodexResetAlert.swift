import CryptoKit
import Foundation

struct CodexResetAlert: Codable, Equatable, Identifiable {
    enum Source: String, Codable, CaseIterable {
        case reset = "codex-reset.com"
        case resets = "codex-resets.com"

        var url: URL { URL(string: "https://\(rawValue)")! }
    }

    enum Kind: String, Codable {
        case clue, scheduled, confirmed, banked

        func title(_ language: AppLanguage) -> String {
            switch (self, language == .simplifiedChinese) {
            case (.clue, true): return "重置线索 · 尚未确认"
            case (.scheduled, true): return "重置预告 · 等待执行"
            case (.confirmed, true): return "站点报告已重置"
            case (.banked, true): return "Banked 重置额度消息"
            case (.clue, false): return "Reset clue · unconfirmed"
            case (.scheduled, false): return "Reset announced · awaiting execution"
            case (.confirmed, false): return "Reset reported by source"
            case (.banked, false): return "Banked reset update"
            }
        }
    }

    /// Stable within one site. Sites deliberately keep separate identities.
    let key: String
    let source: Source
    let kind: Kind
    let publishedAt: Date
    let text: String
    let url: URL
    let scheduledFor: Date?

    var isLocalTest: Bool { key.hasPrefix("local-test:") }

    func sourceTitle(_ language: AppLanguage) -> String {
        isLocalTest ? (language == .simplifiedChinese ? "本机测试（非站点公告）" : "Local test (not a site announcement)") : source.rawValue
    }

    func title(_ language: AppLanguage) -> String {
        isLocalTest ? (language == .simplifiedChinese ? "本机测试提醒" : "Local test reminder") : kind.title(language)
    }

    /// Excludes fetch times, metrics and probabilities. A confirmation or a
    /// changed deadline is new information, even if the post ID stays the same.
    var id: String {
        let payload = [key, kind.rawValue, text, url.absoluteString,
                       scheduledFor.map { String($0.timeIntervalSince1970) } ?? ""].joined(separator: "\n")
        return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    static func link(_ string: String?, fallback: Source) -> URL {
        guard let string, let url = URL(string: string), url.scheme == "https",
              let host = url.host, ["x.com", "twitter.com", "codex-reset.com", "codex-resets.com"].contains(host)
        else { return fallback.url }
        return url
    }

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CodexResetFeed: String, CaseIterable, Codable {
    case timeline, status, history

    var source: CodexResetAlert.Source { self == .timeline ? .reset : .resets }
    var url: URL {
        switch self {
        case .timeline: return URL(string: "https://codex-reset.com/api/timeline")!
        case .status: return URL(string: "https://codex-resets.com/api/v1/status")!
        case .history: return URL(string: "https://codex-resets.com/api/v1/resets?limit=100")!
        }
    }

    func decode(_ data: Data, now: Date = .now) throws -> [CodexResetAlert] {
        let decoder = JSONDecoder()
        switch self {
        case .timeline:
            return try decoder.decode(Timeline.self, from: data).events.compactMap { event in
                guard event.type == "reset" || event.bankedGrant == true || event.resetKind == "banked",
                      let date = CodexResetAlert.date(event.announcedAt), !event.id.isEmpty else { return nil }
                let kind: CodexResetAlert.Kind = event.bankedGrant == true || event.resetKind == "banked" ? .banked
                    : event.preview == true ? .scheduled
                    : event.confirmed == true ? .confirmed : .clue
                return CodexResetAlert(key: "\(source.rawValue):\(event.id)", source: source,
                    kind: kind, publishedAt: date, text: CodexResetAlert.clean(event.summary),
                    url: CodexResetAlert.link(event.url, fallback: source), scheduledFor: CodexResetAlert.date(event.officialWindow?.targetAt ?? event.officialWindow?.endAt))
            }
        case .history:
            return try decoder.decode(History.self, from: data).data.compactMap { $0.alert(kind: nil) }
        case .status:
            let payload = try decoder.decode(Status.self, from: data).data
            var alerts = [payload.latestReset?.alert(kind: nil),
                          payload.scheduledReset?.alert(kind: .scheduled)].compactMap { $0 }
            if let watch = payload.activeWatch,
               let date = CodexResetAlert.date(watch.observedAt),
               let expiry = CodexResetAlert.date(watch.expiresAt), expiry > now {
                // The watch is a robot-classified clue, not an official promise.
                // Its source URL remains stable when its probability changes.
                alerts.append(CodexResetAlert(key: "\(source.rawValue):watch:\(watch.source.url ?? watch.observedAt)",
                    source: source, kind: .clue, publishedAt: date,
                    text: CodexResetAlert.clean(watch.text),
                    url: CodexResetAlert.link(watch.source.url, fallback: source), scheduledFor: nil))
            }
            return alerts
        }
    }

    private struct Timeline: Decodable { let events: [Event] }
    private struct Event: Decodable {
        let id: String
        let type: String
        let summary: String
        let url: String?
        let announcedAt: String?
        let confirmed: Bool?
        let bankedGrant: Bool?
        let resetKind: String?
        let preview: Bool?
        let officialWindow: Window?
        struct Window: Decodable {
            let targetAt: String?
            let endAt: String?
            enum CodingKeys: String, CodingKey { case targetAt = "target_at", endAt = "end_at" }
        }
        enum CodingKeys: String, CodingKey {
            case id, type, summary, url, confirmed
            case announcedAt = "announced_at", bankedGrant = "banked_grant"
            case resetKind = "reset_kind", preview, officialWindow = "official_window"
        }
    }
    private struct Origin: Decodable { let url: String? }
    private struct Reset: Decodable {
        let id: String
        let resetType: String
        let announcedAt: String
        let scheduledFor: String?
        let text: String
        let source: Origin
        enum CodingKeys: String, CodingKey {
            case id, text, source
            case resetType = "reset_type", announcedAt = "announced_at", scheduledFor = "scheduled_for"
        }
        func alert(kind: CodexResetAlert.Kind?) -> CodexResetAlert? {
            guard !id.isEmpty, ["regular", "banked"].contains(resetType),
                  let date = CodexResetAlert.date(announcedAt) else { return nil }
            return CodexResetAlert(key: "codex-resets.com:\(id)", source: .resets,
                kind: kind ?? (resetType == "banked" ? .banked : .confirmed),
                publishedAt: date, text: CodexResetAlert.clean(text),
                url: CodexResetAlert.link(source.url, fallback: .resets),
                scheduledFor: CodexResetAlert.date(scheduledFor))
        }
    }
    private struct History: Decodable { let data: [Reset] }
    private struct Status: Decodable {
        let data: Body
        struct Body: Decodable {
            let latestReset: Reset?
            let scheduledReset: Reset?
            let activeWatch: Watch?
            enum CodingKeys: String, CodingKey {
                case latestReset = "latest_reset", scheduledReset = "scheduled_reset", activeWatch = "active_watch"
            }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                guard [.latestReset, .scheduledReset, .activeWatch].allSatisfy(values.contains) else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                        debugDescription: "Missing reset status fields"))
                }
                latestReset = try values.decodeIfPresent(Reset.self, forKey: .latestReset)
                scheduledReset = try values.decodeIfPresent(Reset.self, forKey: .scheduledReset)
                activeWatch = try values.decodeIfPresent(Watch.self, forKey: .activeWatch)
            }
        }
    }
    private struct Watch: Decodable {
        let observedAt: String
        let expiresAt: String
        let text: String
        let source: Origin
        enum CodingKeys: String, CodingKey {
            case text, source
            case observedAt = "observed_at", expiresAt = "expires_at"
        }
    }
}
