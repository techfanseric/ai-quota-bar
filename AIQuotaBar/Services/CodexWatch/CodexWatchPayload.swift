import Foundation

/// 局域网「关注账号」的数据契约。
///
/// 一台 Mac 只想让别人看到**额度数字**，不需要把 Codex 登录凭据交给任何人：
/// owner 设备自己已经登录了那个账号，它用本地凭据抓到额度，再决定性地把
/// 结果按账号白名单吐给局域网里被授权的对端。对端拿到的永远是快照，
/// 不是 token，也没有任何可用于调用 OpenAI 的东西。
///
/// 这条链路和团队云同步刻意分开：不需要建团队、不经过任何服务器、
/// 账号归属关系只存在于两台设备各自的本机设置里。

/// 一条额度窗口（5h / Weekly / Credits 等）的对外投影。
///
/// 只保留渲染一个额度条所必需的字段。时间戳一律是绝对时间，
/// 对端不做时区假设，直接按 ISO8601 解析。
struct CodexWatchWindow: Codable, Equatable, Sendable {
    /// 窗口名，例如 `5h` / `Weekly` / `Credits`。
    let name: String
    /// 剩余百分比 0...100。额度是百分比语义，不暴露绝对 token 数。
    let remainingPercent: Int
    /// 窗口重置时刻。
    let resetsAt: Date?
    /// 本次抓取时刻，用于对端显示「上次更新」。
    let sampledAt: Date?

    init(
        name: String,
        remainingPercent: Int,
        resetsAt: Date?,
        sampledAt: Date?
    ) {
        self.name = name
        // 对端会把这个数直接当作进度条比例，越界会让 UI 画出负宽度或溢出。
        self.remainingPercent = min(100, max(0, remainingPercent))
        self.resetsAt = resetsAt
        self.sampledAt = sampledAt
    }

    var isShortWindow: Bool {
        let lowered = name.lowercased()
        return lowered.contains("5h") || lowered.contains("hour")
    }
}

/// 一个被授权账号的对外投影。
struct CodexWatchAccount: Codable, Equatable, Sendable {
    /// 账号邮箱。owner 侧按这个值做白名单匹配，因此大小写不敏感。
    let accountName: String
    /// 套餐名，纯展示用（`Pro` / `Plus` / …）。
    let plan: String?
    let windows: [CodexWatchWindow]

    init(accountName: String, plan: String?, windows: [CodexWatchWindow]) {
        let trimmed = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accountName = trimmed
        self.plan = plan
        // 空账号名无法与授权名单匹配，owner 侧在编码前就会剔除。
        self.windows = windows
    }
}

/// owner 设备对一次「关注请求」的应答。
///
/// `status` 刻意把「设备不可达」和「对方没授权」分成两个可区分的状态：
/// 前者让对端显示「离线」，后者显示「等待授权」，这两者的用户动作完全不同，
/// 混成一个 error 会让用户以为该重装点什么。
struct CodexWatchResponse: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        /// 已授权，正常返回账号额度。
        case ok
        /// 令牌认识，但这个账号（或整个功能）没被 owner 授权。
        case notAuthorized
        /// 令牌不认识 / 已轮换。
        case invalidToken
        /// owner 侧功能未开启。
        case disabled
    }

    let status: Status
    /// owner 设备名，方便对端列表里区分「小王的 Mac」这类。
    let hostName: String?
    /// owner 应用版本，排查对端兼容性时有用。
    let appVersion: String?
    /// 服务端生成时刻。
    let generatedAt: Date
    /// 仅 `status == .ok` 时有值。
    let accounts: [CodexWatchAccount]
    /// owner 侧已授权但当前拿不到数据的账号邮箱。
    /// 用于让对端区分「授权了但那台机器没在跑」和「压根没授权」。
    let pendingAccountNames: [String]

    init(
        status: Status,
        hostName: String?,
        appVersion: String?,
        generatedAt: Date,
        accounts: [CodexWatchAccount],
        pendingAccountNames: [String]
    ) {
        self.status = status
        self.hostName = hostName
        self.appVersion = appVersion
        self.generatedAt = generatedAt
        self.accounts = accounts
        self.pendingAccountNames = pendingAccountNames
    }

    static func failure(
        _ status: Status,
        hostName: String? = nil,
        appVersion: String? = nil,
        generatedAt: Date = Date()
    ) -> CodexWatchResponse {
        CodexWatchResponse(
            status: status,
            hostName: hostName,
            appVersion: appVersion,
            generatedAt: generatedAt,
            accounts: [],
            pendingAccountNames: [])
    }
}

/// 授权名单里一条记录的语义。
///
/// owner 侧只需要知道「这个账号邮箱允许被读」，不存任何凭据，
/// 所以这份名单是可以明文落盘的（存在 UserDefaults 里）。
enum CodexWatchGrant: Codable, Equatable, Sendable {
    /// 已授权该邮箱。
    case allowed(String)
    /// owner 明确拒绝该邮箱。显式拒绝优先于默认放行，
    /// 这样「先全局放开、后单点封掉某个账号」是可表达的。
    case denied(String)

    var accountName: String {
        switch self {
        case let .allowed(name), let .denied(name): return name
        }
    }

    var normalizedName: String {
        Self.normalize(accountName)
    }

    var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    /// 大小写与首尾空白归一。邮箱在 ChatGPT 侧本身不区分大小写，
    /// 但 owner 手填时很容易带上空格或大写，不归一会导致「授权了却不生效」。
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// 服务端与客户端共用的路径常量。
///
/// 独立于 `/api/v1/*`（看板）：看板快照是给浏览器渲染的，
/// 会带上账号名掩码、选中模型过滤等展示态决策；关注链路需要一份
/// 不受看板展示设置影响的原始投影，所以单开一个前缀。
enum CodexWatchEndpoint {
    static let quotaPath = "/api/v1/watch/quota"
    /// 局域网地址由用户自己填，服务端不校验 Host，
    /// 但客户端仍然拒绝非 http(s) 且非回环/私网字面量的地址。
    static let defaultPort: UInt16 = 18_765
}
