import Foundation

/// 对端设备的一次抓取结果。
enum CodexWatchFetchResult: Equatable, Sendable {
    /// owner 已授权并返回了额度。
    case ok(CodexWatchResponse)
    /// owner 认识这台对端，但没授权要关注的账号。
    case notAuthorized(CodexWatchResponse)
    /// 令牌不对或已轮换。
    case invalidToken
    /// owner 没开启「被关注」。仍带上应答体，以便对端知道是谁没开。
    case disabled(CodexWatchResponse)
    /// 网络层失败：设备没开机、不在同一个局域网、或地址写错。
    case unreachable(String)
}

/// 读取对端 Mac 的 Codex 额度。
///
/// 三条安全约束，都是从「Bearer 令牌会随每个请求发出去」这个事实推出来的：
///
/// 1. **只发往局域网**：主机必须是回环 / RFC1918 / 链路本地地址字面量，
///    或者一个不带 scheme 的裸主机名。用户手滑把公网地址粘进来时
///    直接拒绝，而不是把令牌发到互联网上。
/// 2. **绝不跟随重定向**：owner 端一个 302 就能把令牌骗到别处去。
/// 3. **令牌不出现在 URL 与错误信息里**：只走 Authorization 头。
struct CodexWatchPeerClient: Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(
                configuration: configuration,
                delegate: CodexWatchRedirectBlocker(),
                delegateQueue: nil)
        }
    }

    func fetch(
        host: String,
        port: UInt16,
        token: String
    ) async -> CodexWatchFetchResult {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { return .invalidToken }
        guard let url = Self.makeURL(host: host, port: port) else {
            return .unreachable("invalid_address")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AIQuotaBar", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            return .unreachable("cancelled")
        } catch {
            // 错误串可能带上 URL，这里不回传给 UI，避免地址以外的细节外泄。
            return .unreachable("network")
        }

        guard let http = response as? HTTPURLResponse else {
            return .unreachable("invalid_response")
        }
        // 401/403 在这里只意味着「令牌不对」。owner 端对未授权的账号
        // 返回 200 + notAuthorized，是有意的区分：403 在这里会让对端
        // 无法告诉用户「你需要在对方设置里勾一下这个账号」。
        guard http.statusCode == 200 else {
            return http.statusCode == 401 || http.statusCode == 403
                ? .invalidToken
                : .unreachable("http_\(http.statusCode)")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(
            CodexWatchResponse.self, from: data)
        else {
            // 版本不兼容时也要能显示，而不是静默失败。
            return .unreachable("incompatible")
        }

        switch payload.status {
        case .ok: return .ok(payload)
        case .notAuthorized: return .notAuthorized(payload)
        case .invalidToken: return .invalidToken
        case .disabled: return .disabled(payload)
        }
    }

    /// 构造请求地址，并把「看起来不像局域网」的输入挡在门外。
    static func makeURL(host: String, port: UInt16) -> URL? {
        var trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 允许用户直接粘 `http://192.168.1.5:18765`，也允许只粘 IP。
        if trimmed.lowercased().hasPrefix("http://") {
            trimmed = String(trimmed.dropFirst("http://".count))
        } else if trimmed.contains("://") {
            // https / 其它 scheme 一律拒绝：局域网服务是明文 HTTP，
            // 假装支持 https 只会让用户填一个连不上的地址。
            return nil
        }
        // 去掉可能带进来的路径与凭据段。
        if let slash = trimmed.firstIndex(of: "/") {
            trimmed = String(trimmed[trimmed.startIndex..<slash])
        }
        guard !trimmed.isEmpty,
              !trimmed.contains("@"),
              !trimmed.contains("?"),
              !trimmed.contains("#"),
              !trimmed.contains(" ")
        else { return nil }

        // 允许用户连端口一起粘进来。
        if let colon = trimmed.lastIndex(of: ":"),
           let parsed = UInt16(trimmed[trimmed.index(after: colon)...]),
           colon != trimmed.startIndex {
            trimmed = String(trimmed[trimmed.startIndex..<colon])
            return makeURL(host: trimmed, port: parsed)
        }
        guard isAllowedHost(trimmed) else { return nil }

        var components = URLComponents()
        components.scheme = "http"
        components.host = trimmed
        components.port = Int(port)
        components.path = CodexWatchEndpoint.quotaPath
        return components.url
    }

    /// 是否允许把 Bearer 令牌发往该主机。
    ///
    /// IP 字面量必须落在回环 / 私有 / 链路本地段；
    /// 裸主机名（如 `studio.local`、内网 DNS）放行，因为局域网里
    /// 用主机名连机器是常规做法，且这类名字解析结果不由本机决定。
    static func isAllowedHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" || lower.hasSuffix(".localhost") {
            return true
        }
        guard let parsed = parseIPv4(host) else { return true }
        switch true {
        case parsed[0] == 127:
            return true
        case parsed[0] == 10:
            return true
        case parsed[0] == 192 && parsed[1] == 168:
            return true
        case parsed[0] == 172 && (16...31).contains(parsed[1]):
            return true
        case parsed[0] == 169 && parsed[1] == 254:
            return true
        default:
            return false
        }
    }

    private static func parseIPv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: [Int] = []
        for part in parts {
            guard let value = Int(part), (0...255).contains(value)
            else { return nil }
            result.append(value)
        }
        return result
    }
}

/// 拒绝一切重定向：跟随会把 Authorization 头带到别的主机上。
private final class CodexWatchRedirectBlocker: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
