import Foundation

/// 一份 auth 文件的身份解读结果。只保留账号指纹与邮箱，不保留任何
/// token / API key 内容。
public struct ParsedCodexAuthLogin: Equatable, Sendable {
    public let accountDigest: String
    public let email: String?
}

/// auth 文件按内容的分类：ChatGPT 登录 / 未登录 / API Key 模式 / 无法读取。
public enum CodexAuthFileStatus: Equatable, Sendable {
    case chatgptLogin(ParsedCodexAuthLogin)
    case unauthenticated
    case apiKeyMode
    case unreadable

    public var isLoggedIn: Bool {
        if case .chatgptLogin = self { return true }
        return false
    }
}

/// 读取任意路径上的 auth JSON（正式 auth.json 或账号池里的备份副本）。
/// Codex 的账号切换功能靠它识别每个文件属于哪个账号。
public enum CodexAuthFileReader {
    /// 解析已读取的 JSON 字典，login 与 UsageAccountObservation 保持同一套
    /// 判定条件（auth_mode 为空或 chatgpt、无 API key、必须带 account_id）。
    static func interpret(_ object: [String: Any]) -> CodexAuthFileStatus {
        if let apiKey = object["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
            return .apiKeyMode
        }
        let mode = object["auth_mode"] as? String
        if let mode, mode != "chatgpt" { return .unauthenticated }
        guard let tokens = object["tokens"] as? [String: Any],
              let id = tokens["account_id"] as? String, !id.isEmpty else {
            return .unauthenticated
        }
        var email: String?
        if let jwt = tokens["id_token"] as? String {
            email = decodeJWTEmail(jwt)
        }
        return .chatgptLogin(ParsedCodexAuthLogin(
            accountDigest: usageDigest("codex-account|" + id),
            email: email))
    }

    /// 读取文件并分类；带撕裂读防护（前后比对 mtime 与大小）。
    public static func read(at url: URL) -> CodexAuthFileStatus {
        guard let before = try? url.resourceValues(
                  forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let size = before.fileSize, size > 0, size < 262_144,
              let data = try? Data(contentsOf: url),
              let after = try? url.resourceValues(
                  forKeys: [.contentModificationDateKey, .fileSizeKey]),
              before.contentModificationDate == after.contentModificationDate,
              before.fileSize == after.fileSize,
              let object = (try? JSONSerialization.jsonObject(with: data))
                  as? [String: Any] else { return .unreadable }
        return interpret(object)
    }

    static func decodeJWTEmail(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var raw = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        raw += String(repeating: "=", count: (4 - raw.count % 4) % 4)
        guard let claims = Data(base64Encoded: raw),
              let object = (try? JSONSerialization.jsonObject(with: claims))
                  as? [String: Any] else { return nil }
        return object["email"] as? String
    }
}
