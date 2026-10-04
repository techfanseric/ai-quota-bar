import CryptoKit
import Foundation

/// 关注链路的云端客户端。刻意独立于 `CloudSyncService`：
///
/// - 团队云同步是**按团队隔离 + 设备凭据**的。关注一个账号不需要团队，也不该
///   有能力借关注之名读到团队数据或设备凭据。
/// - 端点和鉴权用 app 自带的公共服务端点与内置 key（服务端叫 `SYNC_TOKEN`），
///   每个安装都自带，零配置。**它不是鉴权**：它就写在二进制里，谁都能取到。
///   真正的授权是 owner 在设置里逐个勾选那个邮箱——勾了就是「知道这个邮箱的
///   Mac 可以看我的额度」，取消勾选即刻失效。
///
/// 因此地址校验比 app 侧更严：地址在这里是公开查找键，宁可拒绝，也不要归一成一个
/// 意料之外的东西。
struct CodexWatchCloudClient: Sendable {
    enum FetchResult: Equatable, Sendable {
        /// 对方分享了这个邮箱。
        case available(CodexWatchSnapshot)
        /// 云端有快照，但对方太久没上报，数字可能过期。
        case stale(CodexWatchSnapshot)
        /// 没有任何人在分享这个邮箱。这是最常见的状态，必须原样传给 UI。
        case notShared
        /// 网络层失败：离线、服务不可用、版本不兼容。
        case unreachable(String)
    }

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
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: - 写

    /// 发布本机勾选的账号额度。整体替换语义：传空数组就是「全部取消分享」，
    /// 所以撤销不需要单独的接口，也就不会出现删一半、删不干净的情况。
    @discardableResult
    func publish(
        publisher: String,
        snapshots: [CodexWatchAccountSnapshot]
    ) async -> Bool {
        let body: [String: Any] = [
            "publisher": publisher,
            "accounts": snapshots.map { entry in
                [
                    "account": entry.account,
                    "plan": entry.plan ?? NSNull(),
                    "windows": entry.windows.map { window in
                        [
                            "name": window.name,
                            "remainingPercent": window.remainingPercent,
                            "resetsAt": (window.resetsAt.map { ISO8601DateFormatter().string(from: $0) }) ?? NSNull(),
                            "sampledAt": (window.sampledAt.map { ISO8601DateFormatter().string(from: $0) }) ?? NSNull(),
                        ] as [String: Any]
                    },
                ] as [String: Any]
            },
        ]
        var request = makeRequest(path: "/v1/watch/publish", method: "POST")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } catch {
            return false
        }
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// 本机发布的每个账号被读取过多少次。只含计数与时间，不含读取者身份。
    ///
    /// 服务端只存哈希，所以「哈希 → 邮箱」的映射只能在这台知道邮箱的机器上做：
    /// 传入本机已知的地址，逐个算 key 去匹配。
    func fetchReadCounts(
        accounts: [String]
    ) async -> [String: CodexWatchReadCount] {
        guard !accounts.isEmpty else { return [:] }
        let wanted = Dictionary(
            accounts.compactMap { account -> (String, String)? in
                guard let key = Self.accountKey(for: account) else { return nil }
                return (key, CodexWatchStore.normalize(account))
            },
            uniquingKeysWith: { first, _ in first })
        guard !wanted.isEmpty else { return [:] }

        var request = makeRequest(
            path: "/v1/watch/reads?publisher=\(Self.escape(CloudWatchPublisher.current))",
            method: "GET")
        request.timeoutInterval = 8
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [:] }
            let payload = try JSONDecoder().decode(ReadsResponse.self, from: data)
            var result: [String: CodexWatchReadCount] = [:]
            for entry in payload.accounts {
                guard let account = wanted[entry.accountKey] else { continue }
                result[account] = CodexWatchReadCount(
                    readCount: entry.readCount,
                    lastReadAt: Self.parseDate(entry.lastReadAt),
                    stale: entry.stale)
            }
            return result
        } catch {
            return [:]
        }
    }

    // MARK: - 读

    func fetch(account: String) async -> FetchResult {
        let normalized = CodexWatchStore.normalize(account)
        guard CodexWatchStore.isValidAccountName(normalized) else { return .notShared }
        var request = makeRequest(
            path: "/v1/watch/quota?email=\(Self.escape(normalized))", method: "GET")
        request.timeoutInterval = 8
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable("invalid_response")
            }
            switch http.statusCode {
            case 200:
                return .available(try decodeSnapshot(data, fallback: normalized))
            // 404 与 410 都是「这个地址没有可用的额度」，但用户要做的动作不同：
            // 前者是让对方去勾选这个邮箱，后者是让对方把 app 打开。
            case 404: return .notShared
            case 410: return .stale(CodexWatchSnapshot(
                account: normalized, plan: nil, windows: [], publishedAt: nil))
            default: return .unreachable("http_\(http.statusCode)")
            }
        } catch is CancellationError {
            return .unreachable("cancelled")
        } catch {
            // 版本不兼容时也要能显示，而不是静默失败。
            return .unreachable("incompatible")
        }
    }

    // MARK: - 私有

    private func decodeSnapshot(_ data: Data, fallback: String) throws -> CodexWatchSnapshot {
        let payload = try JSONDecoder().decode(QuotaResponse.self, from: data)
        return CodexWatchSnapshot(
            account: payload.account.isEmpty ? fallback : payload.account,
            plan: payload.plan,
            windows: payload.windows.map { window in
                CodexWatchWindow(
                    name: window.name,
                    remainingPercent: window.remainingPercent,
                    resetsAt: Self.parseDate(window.resetsAt),
                    sampledAt: Self.parseDate(window.sampledAt))
            },
            publishedAt: Self.parseDate(payload.updatedAt))
    }

    private func makeRequest(path: String, method: String) -> URLRequest {
        var request = URLRequest(
            url: URL(string: CloudSyncSettings.defaultEndpointURLString + path)
                ?? URL(string: "https://invalid.invalid")!)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // The key travels only in the Authorization header, never in the URL.
        request.setValue("Bearer \(CloudSyncSettings.effectiveToken(""))",
                         forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AIQuotaBar", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    /// 与服务端 `accountKey` 逐字一致的归一 + SHA-256（小写十六进制）。
    /// 两边任何一边改了归一规则，用户就会看到「被查看 0 次」这种假数据。
    static func accountKey(for account: String) -> String? {
        let normalized = CodexWatchStore.normalize(account)
        guard CodexWatchStore.isValidAccountName(normalized) else { return nil }
        return SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - 线格式

    private struct QuotaResponse: Decodable {
        let account: String
        let plan: String?
        let updatedAt: String?
        let windows: [WindowResponse]

        enum CodingKeys: String, CodingKey {
            case account, plan, windows
            case updatedAt = "updated_at"
        }
    }

    private struct WindowResponse: Decodable {
        let name: String
        let remainingPercent: Int
        let resetsAt: String?
        let sampledAt: String?
    }

    private struct ReadsResponse: Decodable {
        let accounts: [ReadEntry]
    }

    private struct ReadEntry: Decodable {
        let accountKey: String
        let readCount: Int
        let lastReadAt: String?
        let stale: Bool

        enum CodingKeys: String, CodingKey {
            case accountKey = "account_key"
            case readCount = "read_count"
            case lastReadAt = "last_read_at"
            case stale
        }
    }
}

/// 本机作为发布方的稳定标识。存在 UserDefaults 里，不是凭据。
enum CloudWatchPublisher {
    static var current: String {
        CloudSyncSettings.current.deviceID
    }
}

/// 一个被分享账号的对外快照。
struct CodexWatchSnapshot: Equatable, Sendable {
    let account: String
    let plan: String?
    let windows: [CodexWatchWindow]
    /// 云端记录的发布时刻，用来判断新鲜度。
    let publishedAt: Date?
}

/// 发布方向服务端提交的形状。
struct CodexWatchAccountSnapshot: Equatable, Sendable {
    let account: String
    let plan: String?
    let windows: [CodexWatchWindow]
}

struct CodexWatchWindow: Equatable, Sendable {
    let name: String
    /// 剩余百分比 0...100。只传百分比，不传绝对量。
    let remainingPercent: Int
    let resetsAt: Date?
    let sampledAt: Date?
}

struct CodexWatchReadCount: Equatable, Sendable {
    let readCount: Int
    let lastReadAt: Date?
    let stale: Bool
}
