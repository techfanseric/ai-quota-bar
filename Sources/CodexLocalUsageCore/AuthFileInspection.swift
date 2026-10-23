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

/// 一份 auth 文件的原始凭据字节与分类结果。
///
/// 守护镜像需要把凭据原样保存下来（换账号、token 刷新后仍然留一份），
/// 所以这里把 data 本身一起交出来，而不只是一个账号指纹。
public struct CodexAuthCredential: Equatable, Sendable {
    public let status: CodexAuthFileStatus
    public let data: Data
    /// 「mtime:size」形式的版本号：文件内容被改写后必然变化。
    public let generation: String

    public init(status: CodexAuthFileStatus, data: Data, generation: String) {
        self.status = status
        self.data = data
        self.generation = generation
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
        guard let credential = readCredential(at: url) else { return .unreadable }
        return credential.status
    }

    /// 读取文件的内容与分类；带撕裂读防护（前后比对 mtime 与大小）。
    ///
    /// 守护镜像要原样保存凭据字节，所以这里把 data 一并返回，
    /// 并给出可用于判断「内容是否变过」的 generation。
    ///
    /// 撕裂防护走 FileStamp（新鲜 stat）而不是 URL.resourceValues——
    /// 后者在同一个 URL 实例上会返回缓存值，比对恒为真。
    public static func readCredential(at url: URL) -> CodexAuthCredential? {
        guard let before = FileStamp.of(url),
              before.size > 0, before.size < 262_144,
              let data = try? Data(contentsOf: url),
              let after = FileStamp.of(url),
              before == after,
              let object = (try? JSONSerialization.jsonObject(with: data))
                  as? [String: Any]
        else { return nil }
        return CodexAuthCredential(
            status: interpret(object),
            data: data,
            generation: before.generation)
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
