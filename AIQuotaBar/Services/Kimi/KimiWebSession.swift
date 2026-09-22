import Foundation

/// A single account and origin. Never probe a second region with the same credential.
struct KimiWebSession: Codable, Sendable {
    let token: String
    let origin: String

    var expiry: Date? { (claims?["exp"] as? Double).map(Date.init(timeIntervalSince1970:)) }
    var accountID: String? { claims?["sub"] as? String }
    var accountLabel: String { accountID.map { "Kimi · \($0)" } ?? "Kimi" }

    private var claims: [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func validated(now: Date = Date()) throws -> Self {
        guard ["https://www.kimi.com", "https://www.kimi.ai"].contains(origin) else {
            throw KimiSessionError.unsupportedOrigin
        }
        guard !token.isEmpty, !token.contains(where: { $0.isWhitespace }) else {
            throw KimiSessionError.invalidStore
        }
        if let expiry = claims?["exp"] as? Double, expiry <= now.timeIntervalSince1970 {
            throw KimiSessionError.expired
        }
        return self
    }
}

enum KimiSessionError: LocalizedError {
    case missing, invalidStore, expired, unsupportedOrigin, keychain(OSStatus), noBrowserSession, multipleBrowserAccounts

    var errorDescription: String? {
        if AppLanguage.current == .simplifiedChinese {
            switch self {
            case .multipleBrowserAccounts: return "检测到多个 Kimi 网页账号，请在高级选项中选择账号，或登录 Kimi 桌面端以优先使用桌面账号。"
            case .missing: return "请先登录 Kimi 桌面端，或选择其他 Kimi 额度来源。"
            case .invalidStore: return "Kimi 登录数据格式不受支持或已损坏，请在 Kimi 中重新登录。"
            case .expired: return "Kimi 登录已失效或无访问权限，请重新登录；网页登录需要重新导入。"
            case .unsupportedOrigin: return "不支持此 Kimi 登录站点，请选择 www.kimi.com 或 www.kimi.ai 的登录态。"
            case .keychain: return "无法读取 Kimi 钥匙串，请在 Kimi 设置中点击「允许读取桌面登录」后重试。"
            case .noBrowserSession: return "未找到有效的 kimi-auth Cookie，请在所选浏览器中登录 kimi.com 后重新导入。"
            }
        }
        switch self {
        case .multipleBrowserAccounts: return "Multiple Kimi web accounts were found. Choose an account in advanced options, or sign in to Kimi Desktop to use that account."
        case .missing: return "Sign in to Kimi Desktop, or select another Kimi data source."
        case .invalidStore: return "The Kimi login format is unsupported or damaged. Sign in to Kimi again."
        case .expired: return "Kimi login expired or access was denied. Sign in again, then refresh Desktop or re-import the web session."
        case .unsupportedOrigin: return "The Kimi login origin is unsupported. Select a session from www.kimi.com or www.kimi.ai."
        case .keychain: return "Kimi Safe Storage is unavailable. Use Allow Desktop Access in Kimi settings, then refresh."
        case .noBrowserSession: return "No valid kimi-auth cookie was found. Sign in to kimi.com in the selected browser, then import again."
        }
    }
}

enum KimiDataSourceMode: String, CaseIterable, Identifiable {
    case auto, desktop, cli, web
    static let storageKey = "kimiSourceMode"
    static let lastSuccessfulSourceKey = "kimiLastSuccessfulSource"
    var id: String { rawValue }
    func title(chinese: Bool) -> String {
        switch self {
        case .auto: return chinese ? "自动检测（推荐）" : "Automatic (recommended)"
        case .desktop: return chinese ? "Kimi 桌面端" : "Kimi Desktop"
        case .cli: return "Kimi Code CLI"
        case .web: return chinese ? "网页登录" : "Web session"
        }
    }
}
