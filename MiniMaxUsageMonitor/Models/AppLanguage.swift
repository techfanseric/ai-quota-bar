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
            case .preferencesSubtitle: return "Tune refresh behavior, menu bar density, and the provider credential used by the monitor."
            case .tabConnection: return "Connection"
            case .tabBehavior: return "Behavior"
            case .tabAppearance: return "Appearance"
            case .connectionEyebrow: return "Connection"
            case .connectionTitle: return "API access"
            case .connectionDescription: return "Your credential is stored in Keychain. Clear the field and save if you want to remove the stored credential."
            case .apiKeyPlaceholder: return "Provider credential"
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
            case .apiKeySaveFailed: return "Credential could not be saved."
            case .menuTitle: return "Usage Monitor"
            case .percentLeft: return "% left"
            case .remaining: return "Remaining"
            case .total: return "Total"
            case .checkingQuota: return "Checking your current quota..."
            case .details: return "Details"
            case .models: return "Models"
            case .modelCount: return "Tracked models"
            case .nextReset: return "Next reset"
            case .mostUrgent: return "Most urgent"
            case .currentQuota: return "Current interval"
            case .weeklyQuota: return "Weekly quota"
            case .noWeeklyCap: return "No weekly cap"
            case .remainingQuota: return "Remaining quota"
            case .usageRatio: return "Usage ratio"
            case .menuBarStyle: return "Menu bar style"
            case .connection: return "Connection"
            case .needsAttention: return "Needs attention"
            case .loading: return "Loading"
            case .menuLoadingHint: return "Fetching the latest model quotas for the menu."
            case .menuConfigureKeyHint: return "Open Settings and add your provider credential to start tracking quota."
            case .menuEmptyModelsHint: return "No model quota data is available yet. Try refreshing in a moment."
            case .menuRefreshHint: return "Refresh failed. You can retry now or review your configuration in Settings."
            case .lastUpdated: return "Last updated"
            case .refresh: return "Refresh"
            case .settings: return "Settings"
            case .updatesEyebrow: return "Updates"
            case .updatesTitle: return "App updates"
            case .updatesDescription: return "Check the latest GitHub release and compare it with your current version."
            case .checkForUpdates: return "Check for updates"
            case .openReleasePage: return "Open release page"
            case .currentVersion: return "Current version"
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
            case .modelSelectionLabel: return "Display model"
            case .modelSelectionPlaceholder: return "Select a model"
            }
        case .simplifiedChinese:
            switch key {
            case .preferences: return "偏好设置"
            case .preferencesSubtitle: return "调整刷新策略、菜单栏显示密度，以及监控器使用的服务商凭据。"
            case .tabConnection: return "连接"
            case .tabBehavior: return "行为"
            case .tabAppearance: return "外观"
            case .connectionEyebrow: return "连接"
            case .connectionTitle: return "API 访问"
            case .connectionDescription: return "凭据会安全保存在钥匙串里。清空输入框并保存即可移除当前已保存的凭据。"
            case .apiKeyPlaceholder: return "服务商凭据"
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
            case .apiKeySaveFailed: return "凭据保存失败。"
            case .menuTitle: return "用量监控"
            case .percentLeft: return "剩余"
            case .remaining: return "剩余"
            case .total: return "总量"
            case .checkingQuota: return "正在检查当前额度..."
            case .details: return "详情"
            case .models: return "模型额度"
            case .modelCount: return "跟踪模型数"
            case .nextReset: return "下次重置"
            case .mostUrgent: return "最紧急模型"
            case .currentQuota: return "当前周期"
            case .weeklyQuota: return "周额度"
            case .noWeeklyCap: return "无周限制"
            case .remainingQuota: return "剩余额度"
            case .usageRatio: return "可用比例"
            case .menuBarStyle: return "菜单栏样式"
            case .connection: return "连接状态"
            case .needsAttention: return "需要处理"
            case .loading: return "加载中"
            case .menuLoadingHint: return "正在拉取菜单里要显示的模型额度。"
            case .menuConfigureKeyHint: return "打开设置并填入服务商凭据后，就可以开始跟踪额度。"
            case .menuEmptyModelsHint: return "暂时还没有可显示的模型额度数据，稍后可以再刷新一次。"
            case .menuRefreshHint: return "刷新失败了，你可以现在重试，或者去设置里检查配置。"
            case .lastUpdated: return "上次更新"
            case .refresh: return "刷新"
            case .settings: return "设置"
            case .updatesEyebrow: return "更新"
            case .updatesTitle: return "应用更新"
            case .updatesDescription: return "检查 GitHub 最新 Release，并与当前版本进行对比。"
            case .checkForUpdates: return "检查更新"
            case .openReleasePage: return "打开发布页"
            case .currentVersion: return "当前版本"
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
            case .modelSelectionLabel: return "显示模型"
            case .modelSelectionPlaceholder: return "选择模型"
            }
        }
    }

    func allProvidersConnectionDescription() -> String {
        switch self {
        case .english:
            return "Configure one or both providers. Each credential is stored separately in Keychain, and all configured providers refresh together."
        case .simplifiedChinese:
            return "可以同时配置一个或多个服务商。每个凭据都会分别保存在钥匙串中，已配置的服务商会一起刷新。"
        }
    }

    func credentialPlaceholder(for provider: UsageProvider) -> String {
        switch (self, provider) {
        case (.english, .miniMax):
            return "MiniMax API key"
        case (.english, .glm):
            return "Paste GLM quota curl command"
        case (.simplifiedChinese, .miniMax):
            return "MiniMax API Key"
        case (.simplifiedChinese, .glm):
            return "粘贴 GLM 额度接口 curl 命令"
        }
    }

    func credentialHelpText(for provider: UsageProvider) -> String {
        switch (self, provider) {
        case (.english, .miniMax):
            return "Use the bearer token for the MiniMax coding plan remains endpoint."
        case (.english, .glm):
            return "Required fields are the quota endpoint URL and authorization header; organization, project, and cookie are preserved when present."
        case (.simplifiedChinese, .miniMax):
            return "填入 MiniMax coding plan remains 接口使用的 Bearer token。"
        case (.simplifiedChinese, .glm):
            return "至少需要额度接口 URL 和 authorization 头；如果 curl 里有组织、项目和 cookie，也会一并保存用于请求。"
        }
    }

    func pasteFromClipboardText() -> String {
        switch self {
        case .english:
            return "Paste from Clipboard"
        case .simplifiedChinese:
            return "从剪贴板粘贴"
        }
    }

    func selectAllText() -> String {
        switch self {
        case .english:
            return "Select All"
        case .simplifiedChinese:
            return "全选"
        }
    }

    func fullQuotaModelsToggleText(count: Int, isExpanded: Bool) -> String {
        switch self {
        case .english:
            return isExpanded ? "Hide \(count) unused full-quota models" : "Show \(count) unused full-quota models"
        case .simplifiedChinese:
            return isExpanded ? "收起 \(count) 个满额度未使用模型" : "展开 \(count) 个满额度未使用模型"
        }
    }

    func allModelsUnusedText() -> String {
        switch self {
        case .english:
            return "All tracked models are still at full quota."
        case .simplifiedChinese:
            return "当前服务商的模型都还没使用，额度都是满的。"
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

    func menuBarCompactText(ready: Int, total: Int) -> String {
        switch self {
        case .english:
            return "\(ready)/\(total)"
        case .simplifiedChinese:
            return "\(ready)/\(total)"
        }
    }

    func readyModelsText(_ count: Int) -> String {
        switch self {
        case .english:
            return "\(count) ready"
        case .simplifiedChinese:
            return "\(count) 可用"
        }
    }

    func readyLabel() -> String {
        switch self {
        case .english:
            return "Ready"
        case .simplifiedChinese:
            return "可用"
        }
    }

    func fullModelsText(_ count: Int) -> String {
        switch self {
        case .english:
            return "\(count) full"
        case .simplifiedChinese:
            return "\(count) 已耗尽"
        }
    }

    func fullLabel() -> String {
        switch self {
        case .english:
            return "Full"
        case .simplifiedChinese:
            return "耗尽"
        }
    }

    func lowModelsText(_ count: Int) -> String {
        switch self {
        case .english:
            return "\(count) low"
        case .simplifiedChinese:
            return "\(count) 偏低"
        }
    }

    func weeklyFullLabel() -> String {
        switch self {
        case .english:
            return "Weekly full"
        case .simplifiedChinese:
            return "周耗尽"
        }
    }

    func weeklyFullModelsText(_ count: Int) -> String {
        switch self {
        case .english:
            return "\(count) weekly full"
        case .simplifiedChinese:
            return "\(count) 周耗尽"
        }
    }

    func weeklyUnusedText() -> String {
        switch self {
        case .english:
            return "Weekly unused"
        case .simplifiedChinese:
            return "周未用"
        }
    }

    func modelsReadyHeadline(ready: Int, total: Int) -> String {
        switch self {
        case .english:
            return "\(ready)/\(total)"
        case .simplifiedChinese:
            return "\(ready)/\(total)"
        }
    }

    func modelsReadyCaption(ready: Int, total: Int) -> String {
        switch self {
        case .english:
            return "\(ready) of \(total) models still have current interval quota."
        case .simplifiedChinese:
            return "共 \(total) 个模型，其中 \(ready) 个当前周期仍有额度。"
        }
    }

    func availabilitySummary(ready: Int, full: Int) -> String {
        switch self {
        case .english:
            return "\(ready) ready, \(full) full"
        case .simplifiedChinese:
            return "\(ready) 个可用，\(full) 个已耗尽"
        }
    }

    func unitsLeftText(_ count: Int) -> String {
        switch self {
        case .english:
            return "\(count) left"
        case .simplifiedChinese:
            return "余 \(count)"
        }
    }

    func fullStatusText() -> String {
        switch self {
        case .english:
            return "Full"
        case .simplifiedChinese:
            return "已耗尽"
        }
    }

    func weeklyFullText() -> String {
        switch self {
        case .english:
            return "Weekly full"
        case .simplifiedChinese:
            return "周额度耗尽"
        }
    }

    func modelUsageCompact(currentUsed: Int, currentTotal: Int) -> String {
        switch self {
        case .english:
            return "Now \(currentUsed)/\(currentTotal)"
        case .simplifiedChinese:
            return "当前 \(currentUsed)/\(currentTotal)"
        }
    }

    func remainingUsageCompact(remaining: Int, total: Int) -> String {
        switch self {
        case .english:
            return "Left \(remaining)/\(total)"
        case .simplifiedChinese:
            return "剩余 \(remaining)/\(total)"
        }
    }

    func weeklyUsageCompact(weeklyUsed: Int, weeklyTotal: Int) -> String {
        switch self {
        case .english:
            return "Week \(weeklyUsed)/\(weeklyTotal)"
        case .simplifiedChinese:
            return "本周 \(weeklyUsed)/\(weeklyTotal)"
        }
    }

    func relativeText(until date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = Locale(identifier: rawValue)
        return formatter.localizedString(for: date, relativeTo: Date())
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

    func updateAvailableText(current: String, latest: String) -> String {
        switch self {
        case .english:
            return "Update available: \(current) -> \(latest)"
        case .simplifiedChinese:
            return "发现新版本：\(current) -> \(latest)"
        }
    }

    func upToDateText(current: String) -> String {
        switch self {
        case .english:
            return "You're up to date (\(current))."
        case .simplifiedChinese:
            return "已是最新版本（\(current)）。"
        }
    }

    func updateCheckFailedText(_ message: String) -> String {
        switch self {
        case .english:
            return "Update check failed: \(message)"
        case .simplifiedChinese:
            return "检查更新失败：\(message)"
        }
    }

    func updateNotificationTitle() -> String {
        switch self {
        case .english:
            return "MiniMax Usage Monitor Update"
        case .simplifiedChinese:
            return "MiniMax Usage Monitor 有新版本"
        }
    }

    func updateNotificationBody(current: String, latest: String) -> String {
        switch self {
        case .english:
            return "New version \(latest) is available (current: \(current))."
        case .simplifiedChinese:
            return "发现新版本 \(latest)（当前版本：\(current)）。"
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

    func specificModelStatus(for model: ModelUsageData?) -> String {
        guard let model = model else { return "—" }
        let remaining = model.currentIntervalRemaining
        let resetMinutes = minutesUntilReset(model.endTime)

        if resetMinutes <= 0 {
            return "\(remaining)"
        }

        let resetText: String
        if resetMinutes >= 60 {
            let hours = resetMinutes / 60
            resetText = "\(hours)h"
        } else {
            resetText = "\(resetMinutes)m"
        }

        switch self {
        case .english:
            return "\(remaining) (\(resetText))"
        case .simplifiedChinese:
            return "\(remaining) (\(resetText))"
        }
    }

    private func minutesUntilReset(_ endTime: Date?) -> Int {
        guard let endTime = endTime else { return 0 }
        let interval = endTime.timeIntervalSince(Date())
        return max(0, Int(interval / 60))
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
    case nextReset
    case mostUrgent
    case currentQuota
    case weeklyQuota
    case noWeeklyCap
    case remainingQuota
    case usageRatio
    case menuBarStyle
    case connection
    case needsAttention
    case loading
    case menuLoadingHint
    case menuConfigureKeyHint
    case menuEmptyModelsHint
    case menuRefreshHint
    case lastUpdated
    case refresh
    case settings
    case updatesEyebrow
    case updatesTitle
    case updatesDescription
    case checkForUpdates
    case openReleasePage
    case currentVersion
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
    case modelSelectionLabel
    case modelSelectionPlaceholder
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
        case (.specificModel, .english):
            return "Primary Model"
        case (.numberOnly, .simplifiedChinese):
            return "紧凑"
        case (.numberWithUnit, .simplifiedChinese):
            return "详细"
        case (.leveled, .simplifiedChinese):
            return "智能"
        case (.specificModel, .simplifiedChinese):
            return "主模型"
        }
    }

    func caption(language: AppLanguage) -> String {
        switch (self, language) {
        case (.numberOnly, .english):
            return "Show how many models are still available at a glance."
        case (.numberWithUnit, .english):
            return "Use a short textual summary of model availability."
        case (.leveled, .english):
            return "Switch to warnings automatically when some models are tight."
        case (.specificModel, .english):
            return "Show the primary model's remaining count and reset time."
        case (.numberOnly, .simplifiedChinese):
            return "用最紧凑的方式显示可用模型数。"
        case (.numberWithUnit, .simplifiedChinese):
            return "用简短文案展示模型可用情况。"
        case (.leveled, .simplifiedChinese):
            return "平时保持简洁，模型额度紧张时自动切换成提醒语义。"
        case (.specificModel, .simplifiedChinese):
            return "显示主模型的剩余次数和重置时间。"
        }
    }

    func preview(language: AppLanguage) -> String {
        switch (self, language) {
        case (.numberOnly, _):
            return "4/6"
        case (.numberWithUnit, .english):
            return "4 ready"
        case (.numberWithUnit, .simplifiedChinese):
            return "4 可用"
        case (.leveled, .english):
            return "1 full"
        case (.leveled, .simplifiedChinese):
            return "1 已耗尽"
        case (.specificModel, .english):
            return "1101/44.40h"
        case (.specificModel, .simplifiedChinese):
            return "1101/44.40h"
        }
    }
}
