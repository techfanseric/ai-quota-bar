import Foundation

enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let storageKey = "appLanguage"

    var id: String { rawValue }

    static var current: AppLanguage {
        if let rawValue = UserDefaults.standard.string(forKey: storageKey),
           let language = AppLanguage(rawValue: rawValue) {
            return language
        }

        return fallback
    }

    static var fallback: AppLanguage {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .simplifiedChinese : .english
    }

    var displayName: String {
        switch self {
        case .english:
            return "English"
        case .simplifiedChinese:
            return "简体中文"
        }
    }

    func text(_ key: AppText) -> String {
        switch self {
        case .english:
            switch key {
            case .preferences: return "Preferences"
            case .preferencesSubtitle: return "Tune refresh behavior, menu bar density, and the MiniMax API key used by the monitor."
            case .tabConnection: return "Connection"
            case .tabBehavior: return "Behavior"
            case .tabAppearance: return "Appearance"
            case .connectionEyebrow: return "Connection"
            case .connectionTitle: return "API access"
            case .connectionDescription: return "Your key is stored in Keychain. Clear the field and save if you want to remove the stored key."
            case .apiKeyPlaceholder: return "MiniMax API key"
            case .testConnection: return "Test connection"
            case .behaviorEyebrow: return "Behavior"
            case .behaviorTitle: return "Refresh cadence"
            case .behaviorDescription: return "Use a steady interval so the menu bar stays current without feeling noisy."
            case .refreshInterval: return "Refresh interval"
            case .refreshIntervalDescription: return "Applies to the background polling timer."
            case .lowQuotaWarning: return "Low-quota warning"
            case .lowQuotaWarningDescription: return "Show the reminder panel once the remaining percentage drops below this threshold."
            case .refreshOnLaunch: return "Refresh on launch"
            case .refreshOnLaunchDescription: return "Immediately fetch quota after the menu bar item appears."
            case .appearanceEyebrow: return "Appearance"
            case .appearanceTitle: return "Menu bar display"
            case .appearanceDescription: return "Pick how much detail should appear in the compact status item."
            case .languageTitle: return "App language"
            case .languageDescription: return "Choose the language used by the app interface."
            case .changesApply: return "Changes apply as soon as you save them."
            case .saveChanges: return "Save Changes"
            case .testConnectionSuccess: return "Connection looks good."
            case .testConnectionRejected: return "The API rejected this key."
            case .settingsSaved: return "Settings saved."
            case .apiKeySaveFailed: return "API key could not be saved."
            case .menuTitle: return "MiniMax Usage"
            case .percentLeft: return "% left"
            case .remaining: return "Remaining"
            case .total: return "Total"
            case .checkingQuota: return "Checking your current quota..."
            case .details: return "Details"
            case .models: return "Models"
            case .modelCount: return "Tracked models"
            case .currentQuota: return "Current interval"
            case .weeklyQuota: return "Weekly quota"
            case .noWeeklyCap: return "No weekly cap"
            case .remainingQuota: return "Remaining quota"
            case .usageRatio: return "Usage ratio"
            case .menuBarStyle: return "Menu bar style"
            case .connection: return "Connection"
            case .needsAttention: return "Needs attention"
            case .loading: return "Loading"
            case .lastUpdated: return "Last updated"
            case .refresh: return "Refresh"
            case .settings: return "Settings"
            case .quitApp: return "Quit MiniMax Usage Monitor"
            case .statusRefreshing: return "Refreshing"
            case .statusAttention: return "Attention"
            case .statusLowQuota: return "Low quota"
            case .statusHealthy: return "Healthy"
            case .statusChecking: return "Checking"
            case .statusFetchingSnapshot: return "Fetching the latest quota snapshot."
            case .statusApproachingThreshold: return "You are approaching the warning threshold."
            case .statusStable: return "Everything looks stable right now."
            case .statusWaitingFirstRefresh: return "Waiting for the first successful refresh."
            case .warningPanelTitle: return "Low Quota Warning"
            case .warningRemaining: return "Remaining:"
            case .warningTime: return "Time:"
            case .warningEstExhaustion: return "Est. exhaustion:"
            case .errorInvalidURL: return "Invalid API URL"
            case .errorNetwork: return "Network error"
            case .errorInvalidResponse: return "Invalid response from server"
            case .errorAPI: return "API error"
            case .errorKeychain: return "Keychain access error"
            case .errorNotConfigured: return "API key not configured"
            case .unknownError: return "Unknown error"
            }
        case .simplifiedChinese:
            switch key {
            case .preferences: return "偏好设置"
            case .preferencesSubtitle: return "调整刷新策略、菜单栏显示密度，以及监控器使用的 MiniMax API Key。"
            case .tabConnection: return "连接"
            case .tabBehavior: return "行为"
            case .tabAppearance: return "外观"
            case .connectionEyebrow: return "连接"
            case .connectionTitle: return "API 访问"
            case .connectionDescription: return "API Key 会安全保存在钥匙串里。清空输入框并保存即可移除当前已保存的 Key。"
            case .apiKeyPlaceholder: return "MiniMax API Key"
            case .testConnection: return "测试连接"
            case .behaviorEyebrow: return "行为"
            case .behaviorTitle: return "刷新策略"
            case .behaviorDescription: return "设置一个稳定的刷新节奏，让菜单栏信息保持及时，又不会太打扰。"
            case .refreshInterval: return "刷新间隔"
            case .refreshIntervalDescription: return "这个间隔会用于后台轮询定时器。"
            case .lowQuotaWarning: return "低额度提醒"
            case .lowQuotaWarningDescription: return "当剩余额度百分比低于这个阈值时，显示提醒面板。"
            case .refreshOnLaunch: return "启动时刷新"
            case .refreshOnLaunchDescription: return "菜单栏应用启动后立刻请求一次最新额度。"
            case .appearanceEyebrow: return "外观"
            case .appearanceTitle: return "菜单栏显示"
            case .appearanceDescription: return "决定菜单栏这个紧凑状态位里显示多少信息。"
            case .languageTitle: return "界面语言"
            case .languageDescription: return "选择应用界面的显示语言。"
            case .changesApply: return "保存后会立即生效。"
            case .saveChanges: return "保存更改"
            case .testConnectionSuccess: return "连接正常。"
            case .testConnectionRejected: return "这个 API Key 未通过校验。"
            case .settingsSaved: return "设置已保存。"
            case .apiKeySaveFailed: return "API Key 保存失败。"
            case .menuTitle: return "MiniMax 用量"
            case .percentLeft: return "剩余"
            case .remaining: return "剩余"
            case .total: return "总量"
            case .checkingQuota: return "正在检查当前额度..."
            case .details: return "详情"
            case .models: return "模型额度"
            case .modelCount: return "跟踪模型数"
            case .currentQuota: return "当前周期"
            case .weeklyQuota: return "周额度"
            case .noWeeklyCap: return "无周限制"
            case .remainingQuota: return "剩余额度"
            case .usageRatio: return "可用比例"
            case .menuBarStyle: return "菜单栏样式"
            case .connection: return "连接状态"
            case .needsAttention: return "需要处理"
            case .loading: return "加载中"
            case .lastUpdated: return "上次更新"
            case .refresh: return "刷新"
            case .settings: return "设置"
            case .quitApp: return "退出 MiniMax Usage Monitor"
            case .statusRefreshing: return "刷新中"
            case .statusAttention: return "需要注意"
            case .statusLowQuota: return "额度偏低"
            case .statusHealthy: return "状态正常"
            case .statusChecking: return "检查中"
            case .statusFetchingSnapshot: return "正在拉取最新额度快照。"
            case .statusApproachingThreshold: return "当前额度已经接近提醒阈值。"
            case .statusStable: return "当前额度状态比较稳定。"
            case .statusWaitingFirstRefresh: return "正在等待首次成功刷新。"
            case .warningPanelTitle: return "额度不足提醒"
            case .warningRemaining: return "剩余："
            case .warningTime: return "时间："
            case .warningEstExhaustion: return "预计耗尽："
            case .errorInvalidURL: return "API 地址无效"
            case .errorNetwork: return "网络错误"
            case .errorInvalidResponse: return "服务端返回无效响应"
            case .errorAPI: return "API 错误"
            case .errorKeychain: return "钥匙串访问失败"
            case .errorNotConfigured: return "尚未配置 API Key"
            case .unknownError: return "未知错误"
            }
        }
    }

    func availablePercentageText(_ percentage: Int) -> String {
        switch self {
        case .english:
            return "\(percentage)% available"
        case .simplifiedChinese:
            return "可用 \(percentage)%"
        }
    }

    func usageProgressText(used: Int, total: Int) -> String {
        switch self {
        case .english:
            return "\(used) / \(total)"
        case .simplifiedChinese:
            return "\(used) / \(total)"
        }
    }

    func estimatedDaysText(_ days: Int) -> String {
        switch self {
        case .english:
            return "~ \(days) day\(days == 1 ? "" : "s")"
        case .simplifiedChinese:
            return "约 \(days) 天"
        }
    }

    func secondsText(_ seconds: Int) -> String {
        switch self {
        case .english:
            return "\(seconds)s"
        case .simplifiedChinese:
            return "\(seconds) 秒"
        }
    }

    func apiStatusMessage(statusCode: Int, message: String) -> String {
        switch self {
        case .english:
            return "Status \(statusCode): \(message)"
        case .simplifiedChinese:
            return "状态码 \(statusCode)：\(message)"
        }
    }

    func errorDescription(for error: UsageError) -> String {
        switch error {
        case .invalidURL:
            return text(.errorInvalidURL)
        case .networkError(let wrappedError):
            return "\(text(.errorNetwork)): \(wrappedError.localizedDescription)"
        case .invalidResponse:
            return text(.errorInvalidResponse)
        case .apiError(let message):
            return "\(text(.errorAPI)): \(message)"
        case .keychainError:
            return text(.errorKeychain)
        case .notConfigured:
            return text(.errorNotConfigured)
        }
    }
}

enum AppText {
    case preferences
    case preferencesSubtitle
    case tabConnection
    case tabBehavior
    case tabAppearance
    case connectionEyebrow
    case connectionTitle
    case connectionDescription
    case apiKeyPlaceholder
    case testConnection
    case behaviorEyebrow
    case behaviorTitle
    case behaviorDescription
    case refreshInterval
    case refreshIntervalDescription
    case lowQuotaWarning
    case lowQuotaWarningDescription
    case refreshOnLaunch
    case refreshOnLaunchDescription
    case appearanceEyebrow
    case appearanceTitle
    case appearanceDescription
    case languageTitle
    case languageDescription
    case changesApply
    case saveChanges
    case testConnectionSuccess
    case testConnectionRejected
    case settingsSaved
    case apiKeySaveFailed
    case menuTitle
    case percentLeft
    case remaining
    case total
    case checkingQuota
    case details
    case models
    case modelCount
    case currentQuota
    case weeklyQuota
    case noWeeklyCap
    case remainingQuota
    case usageRatio
    case menuBarStyle
    case connection
    case needsAttention
    case loading
    case lastUpdated
    case refresh
    case settings
    case quitApp
    case statusRefreshing
    case statusAttention
    case statusLowQuota
    case statusHealthy
    case statusChecking
    case statusFetchingSnapshot
    case statusApproachingThreshold
    case statusStable
    case statusWaitingFirstRefresh
    case warningPanelTitle
    case warningRemaining
    case warningTime
    case warningEstExhaustion
    case errorInvalidURL
    case errorNetwork
    case errorInvalidResponse
    case errorAPI
    case errorKeychain
    case errorNotConfigured
    case unknownError
}

extension DisplayFormat {
    func title(language: AppLanguage) -> String {
        switch (self, language) {
        case (.numberOnly, .english):
            return "Compact"
        case (.numberWithUnit, .english):
            return "Detailed"
        case (.leveled, .english):
            return "Smart"
        case (.numberOnly, .simplifiedChinese):
            return "紧凑"
        case (.numberWithUnit, .simplifiedChinese):
            return "详细"
        case (.leveled, .simplifiedChinese):
            return "智能"
        }
    }

    func caption(language: AppLanguage) -> String {
        switch (self, language) {
        case (.numberOnly, .english):
            return "Keep the menu bar as concise as possible."
        case (.numberWithUnit, .english):
            return "Show the percentage together with context."
        case (.leveled, .english):
            return "Stay compact until quota starts getting low."
        case (.numberOnly, .simplifiedChinese):
            return "尽量保持菜单栏显示紧凑。"
        case (.numberWithUnit, .simplifiedChinese):
            return "显示百分比，并带上额外语义。"
        case (.leveled, .simplifiedChinese):
            return "平时保持简洁，额度偏低时显示更多提醒信息。"
        }
    }

    func preview(language: AppLanguage) -> String {
        switch (self, language) {
        case (.numberOnly, _):
            return "85%"
        case (.numberWithUnit, .english):
            return "85% remaining"
        case (.numberWithUnit, .simplifiedChinese):
            return "剩余 85%"
        case (.leveled, .english):
            return "[Warning] 18% (~5 days)"
        case (.leveled, .simplifiedChinese):
            return "[提醒] 18% (约 5 天)"
        }
    }
}
