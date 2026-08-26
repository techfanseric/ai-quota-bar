import CodexBarCore
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
            case .tabGeneral: return "General"
            case .tabUsage: return "Usage"
            case .tabSync: return "Sync"
            case .tabProviders: return "Providers"
            case .tabAbout: return "About"
            case .providersTitle: return "Providers"
            case .systemTitle: return "System"
            case .usageTitle: return "Usage"
            case .cloudSyncTitle: return "Cloud sync"
            case .cloudSyncEnabled: return "Enable cloud sync"
            case .cloudSyncEnabledDescription: return "Back up compact quota snapshots with the built-in cloud service. Custom servers are optional."
            case .cloudSyncOpenData: return "View data"
            case .cloudSyncStatusIdle: return "Cloud backup has not run yet."
            case .appTitle: return "About"
            case .appDescription: return "AI Quota Bar keeps your menu bar in sync with the latest coding plan quota."
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
            case .appearanceTitle: return "Language"
            case .appearanceDescription: return "Choose the language used across the app."
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
            case .updatesDescription: return "Check the latest app version and compare it with your current version."
            case .checkForUpdates: return "Check for updates"
            case .openReleasePage: return "Open release page"
            case .currentVersion: return "Current version"
            case .quitApp: return "Quit AI Quota Bar"
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
            case .launchAtLogin: return "Launch at login"
            case .launchAtLoginDescription: return "Automatically start AIQuotaBar when you log in."
            }
        case .simplifiedChinese:
            switch key {
            case .preferences: return "偏好设置"
            case .preferencesSubtitle: return "调整刷新策略、菜单栏显示密度，以及监控器使用的服务商凭据。"
            case .tabGeneral: return "通用"
            case .tabUsage: return "用量"
            case .tabSync: return "同步"
            case .tabProviders: return "服务商"
            case .tabAbout: return "关于"
            case .providersTitle: return "服务商"
            case .systemTitle: return "系统"
            case .usageTitle: return "用量"
            case .cloudSyncTitle: return "云同步"
            case .cloudSyncEnabled: return "启用云同步"
            case .cloudSyncEnabledDescription: return "使用内置云服务备份精简额度快照；自定义服务器是可选项。"
            case .cloudSyncOpenData: return "查看数据"
            case .cloudSyncStatusIdle: return "云端备份尚未运行。"
            case .appTitle: return "关于"
            case .appDescription: return "AI Quota Bar 帮你把最新编程额度实时同步到菜单栏。"
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
            case .appearanceTitle: return "语言"
            case .appearanceDescription: return "选择应用所使用的语言。"
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
            case .updatesDescription: return "检查应用最新版本，并与当前版本进行对比。"
            case .checkForUpdates: return "检查更新"
            case .openReleasePage: return "打开发布页"
            case .currentVersion: return "当前版本"
            case .quitApp: return "退出 AI Quota Bar"
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
            case .launchAtLogin: return "登录时启动"
            case .launchAtLoginDescription: return "登录时自动启动 AIQuotaBar。"
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
        case (.english, .codex):
            return "Codex account email"
        case (.english, .kimi):
            return "Kimi Code API key (optional)"
        case (.simplifiedChinese, .miniMax):
            return "MiniMax API Key"
        case (.simplifiedChinese, .glm):
            return "粘贴 GLM 额度接口 curl 命令"
        case (.simplifiedChinese, .codex):
            return "Codex 账号邮箱"
        case (.simplifiedChinese, .kimi):
            return "Kimi Code API Key（可选）"
        }
    }

    func credentialHelpText(for provider: UsageProvider) -> String {
        switch (self, provider) {
        case (.english, .miniMax):
            return "Use the bearer token for the MiniMax coding plan remains endpoint."
        case (.english, .glm):
            return "Required fields are the quota endpoint URL and authorization header; organization, project, and cookie are preserved when present."
        case (.english, .codex):
            return "Codex is configured through the codexbar subsystem. Use the Codex section above to manage accounts and source mode."
        case (.english, .kimi):
            return "Optional. Leave blank to read quota from the current Kimi Code CLI login through its local `/status` command; otherwise enter a Kimi Code API key stored in Keychain."
        case (.simplifiedChinese, .miniMax):
            return "填入 MiniMax coding plan remains 接口使用的 Bearer token。"
        case (.simplifiedChinese, .glm):
            return "至少需要额度接口 URL 和 authorization 头；如果 curl 里有组织、项目和 cookie，也会一并保存用于请求。"
        case (.simplifiedChinese, .codex):
            return "Codex 通过 codexbar 子系统配置。请使用上方的 Codex 区管理账号和数据源模式。"
        case (.simplifiedChinese, .kimi):
            return "可选。留空时通过本机 `/status` 指令读取当前 Kimi Code CLI 登录的配额；也可以填写 Kimi Code API Key 并保存到钥匙串。"
        }
    }

    func codexAccountsHelpText() -> String {
        switch self {
        case .english:
            return "Codex reads usage via the codexbar subsystem. Choose a source mode; the app will pick a matching account automatically."
        case .simplifiedChinese:
            return "Codex 通过 codexbar 子系统读取额度。请选择数据源模式，App 会自动选用匹配的账号。"
        }
    }

    func codexAccountAddButtonText() -> String {
        switch self {
        case .english:
            return "Add account"
        case .simplifiedChinese:
            return "添加账号"
        }
    }

    func codexAccountEmptyStateText() -> String {
        switch self {
        case .english:
            return "Codex not configured — run `codex` in Terminal to sign in, then click Add account."
        case .simplifiedChinese:
            return "尚未配置 Codex —— 请先在终端运行 `codex` 完成登录，再点击「添加账号」。"
        }
    }

    func codexMenuNotConfiguredTitle() -> String {
        switch self {
        case .english:
            return "Codex not configured"
        case .simplifiedChinese:
            return "Codex 未配置"
        }
    }

    func codexMenuNotConfiguredMessage() -> String {
        switch self {
        case .english:
            return "Run `codex` in Terminal to sign in, then return to Settings → Codex to add the account."
        case .simplifiedChinese:
            return "在终端运行 `codex` 完成登录后，回到「设置 → Codex」添加账号。"
        }
    }

    func codexAccountRefreshButtonText() -> String {
        switch self {
        case .english:
            return "Refresh"
        case .simplifiedChinese:
            return "刷新"
        }
    }

    func codexAccountSignOutButtonText() -> String {
        switch self {
        case .english:
            return "Sign out"
        case .simplifiedChinese:
            return "退出登录"
        }
    }

    func codexAccountRemoveButtonText() -> String {
        switch self {
        case .english:
            return "Remove"
        case .simplifiedChinese:
            return "移除"
        }
    }

    func codexSourceModeLabel() -> String {
        switch self {
        case .english:
            return "Source"
        case .simplifiedChinese:
            return "数据源"
        }
    }

    func codexSourceModeDisplayName(_ mode: CodexDataSourceMode) -> String {
        switch (self, mode) {
        case (.english, .auto): return "Auto"
        case (.english, .oauth): return "OAuth"
        case (.english, .cli): return "CLI"
        case (.english, .web): return "Web dashboard"
        case (.simplifiedChinese, .auto): return "自动"
        case (.simplifiedChinese, .oauth): return "OAuth"
        case (.simplifiedChinese, .cli): return "CLI"
        case (.simplifiedChinese, .web): return "Web 控制台"
        }
    }

    func codexLastRefreshedText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: rawValue)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM-dd HH:mm"
        let formatted = formatter.string(from: date)
        switch self {
        case .english:
            return "Last refreshed \(formatted)"
        case .simplifiedChinese:
            return "上次刷新 \(formatted)"
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

    func updatedAgoText(from date: Date, now: Date = Date()) -> String {
        let minutes = Int((now.timeIntervalSince(date) / 60).rounded(.down))
        switch self {
        case .english:
            if minutes < 1 {
                return "Updated just now"
            }
            return "Updated \(minutes)m ago"
        case .simplifiedChinese:
            if minutes < 1 {
                return "刚刚更新"
            }
            return "\(minutes) 分钟前更新"
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
            return "AI Quota Bar Update"
        case .simplifiedChinese:
            return "AI Quota Bar 有新版本"
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

    /// MiniMax providerHeader 右侧的套餐副标题。
    /// title 取 `-` 前的部分（API 原值通常是 "TokenPlanMax-年度会员" 这种）；
    /// endTime 为 nil 时只显示套餐名；title 全空时返回 nil 让上层走默认 ready/total。
    func miniMaxSubscribeSubtitle(title: String, endTime: Date?) -> String? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortTitle = trimmedTitle.components(separatedBy: "-").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmedTitle
        guard !shortTitle.isEmpty else { return nil }

        guard let endTime else {
            return shortTitle
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        let dateText = formatter.string(from: endTime)

        switch self {
        case .english:
            return "\(shortTitle) · expires \(dateText)"
        case .simplifiedChinese:
            return "\(shortTitle) · 到期 \(dateText)"
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

    func cloudSyncEyebrowText() -> String {
        switch self {
        case .english:
            return "Cloud"
        case .simplifiedChinese:
            return "云端"
        }
    }

    func cloudSyncTitleText() -> String {
        switch self {
        case .english:
            return "Cloud backup"
        case .simplifiedChinese:
            return "云端备份"
        }
    }

    func cloudSyncDescriptionText() -> String {
        switch self {
        case .english:
            return "Back up quota snapshots to your own free Cloudflare D1 database. Provider credentials stay in Keychain."
        case .simplifiedChinese:
            return "把额度快照备份到你自己的免费 Cloudflare D1 数据库。服务商凭据仍只保存在钥匙串。"
        }
    }

    func cloudSyncEnableText() -> String {
        switch self {
        case .english:
            return "Enable cloud backup"
        case .simplifiedChinese:
            return "启用云端备份"
        }
    }

    func cloudSyncEnableDescriptionText() -> String {
        switch self {
        case .english:
            return "Each successful refresh uploads a compact history snapshot to AI Quota Bar's built-in cloud service in the background."
        case .simplifiedChinese:
            return "每次成功刷新后，会在后台把精简历史快照上传到 AI Quota Bar 内置云服务。"
        }
    }

    func cloudSyncStatusSuccess(relative: String) -> String {
        switch self {
        case .english:
            return "Last sync \(relative)."
        case .simplifiedChinese:
            return "上次同步 \(relative)。"
        }
    }

    func cloudSyncStatusFailure(relative: String, detail: String) -> String {
        switch self {
        case .english:
            return "Last sync failed \(relative): \(detail)"
        case .simplifiedChinese:
            return "上次同步失败（\(relative)）：\(detail)"
        }
    }

    func cloudSyncViewDataText() -> String {
        switch self {
        case .english:
            return "View data"
        case .simplifiedChinese:
            return "查看数据"
        }
    }

    func cloudSyncReportOpenedText() -> String {
        switch self {
        case .english:
            return "Data report opened."
        case .simplifiedChinese:
            return "数据报表已打开。"
        }
    }

    func cloudDataRetentionLimitLabel() -> String {
        switch self {
        case .english:
            return "Cloud data retention"
        case .simplifiedChinese:
            return "云端数据保留"
        }
    }

    func cloudDataRetentionLimitDescription() -> String {
        switch self {
        case .english:
            return "Deletes Cloud samples older than this value during sync. Default is 30 days; maximum is 180 days."
        case .simplifiedChinese:
            return "同步时清理早于该范围的 Cloud samples。默认 30 天，最长 180 天。"
        }
    }

    func cloudDataRetentionLimitDisplayName(_ limit: CloudDataRetentionLimit) -> String {
        switch (self, limit) {
        case (.english, .sevenDays): return "7 days"
        case (.english, .fourteenDays): return "14 days"
        case (.english, .thirtyDays): return "30 days"
        case (.english, .sixtyDays): return "60 days"
        case (.english, .ninetyDays): return "90 days"
        case (.english, .oneHundredEightyDays): return "180 days"
        case (.simplifiedChinese, .sevenDays): return "7 天"
        case (.simplifiedChinese, .fourteenDays): return "14 天"
        case (.simplifiedChinese, .thirtyDays): return "30 天"
        case (.simplifiedChinese, .sixtyDays): return "60 天"
        case (.simplifiedChinese, .ninetyDays): return "90 天"
        case (.simplifiedChinese, .oneHundredEightyDays): return "180 天"
        }
    }

    func usageRefreshSectionTitle() -> String {
        switch self {
        case .english:
            return "Refresh"
        case .simplifiedChinese:
            return "刷新"
        }
    }

    func leftClickMenuDisplayTitle() -> String {
        switch self {
        case .english: return "Left-click menu display"
        case .simplifiedChinese: return "左键菜单展示"
        }
    }

    func leftClickMenuDisplayDescription() -> String {
        switch self {
        case .english:
            return "Choose which accounts and quota dimensions appear after clicking the menu bar icon. Refreshing, history, alerts, and sync are not affected."
        case .simplifiedChinese:
            return "选择点击菜单栏图标后显示的账号和额度维度。后台刷新、历史记录、告警和同步不受影响。"
        }
    }

    func leftClickMenuShowAll() -> String {
        switch self {
        case .english: return "Show all"
        case .simplifiedChinese: return "全部显示"
        }
    }

    func leftClickMenuVisibleCount(visible: Int, total: Int) -> String {
        switch self {
        case .english: return "Showing \(visible) of \(total)"
        case .simplifiedChinese: return "显示 \(visible) / \(total)"
        }
    }

    func leftClickMenuModelsEmpty() -> String {
        switch self {
        case .english:
            return "No quota dimensions are available yet. Refresh usage data, then return here to customize the menu."
        case .simplifiedChinese:
            return "暂时没有可选的额度维度。刷新用量数据后，可返回此处自定义菜单。"
        }
    }

    func leftClickMenuDefaultAccount() -> String {
        switch self {
        case .english: return "Default account"
        case .simplifiedChinese: return "默认账户"
        }
    }

    func leftClickMenuAllHiddenTitle() -> String {
        switch self {
        case .english: return "All menu items are hidden"
        case .simplifiedChinese: return "左键菜单项目已全部隐藏"
        }
    }

    func leftClickMenuAllHiddenDescription() -> String {
        switch self {
        case .english: return "Open Settings → Usage to show an account or quota dimension."
        case .simplifiedChinese: return "请在“设置 → 用量”中重新显示账号或额度维度。"
        }
    }

    func usageHistorySectionTitle() -> String {
        switch self {
        case .english:
            return "History"
        case .simplifiedChinese:
            return "历史"
        }
    }

    func quotaForecastLookbackLabel() -> String {
        switch self {
        case .english: return "Consumption forecast"
        case .simplifiedChinese: return "消耗趋势预测"
        }
    }

    func quotaForecastLookbackDescription() -> String {
        switch self {
        case .english:
            return "Show faint projections using the latest 1–5 refresh intervals. Flat usage and quota resets are ignored."
        case .simplifiedChinese:
            return "按最近 1–5 个刷新区间显示淡色预测线；无消耗和额度重置不会参与预测。"
        }
    }

    func quotaForecastIntervalCount(_ count: Int) -> String {
        switch self {
        case .english: return count == 1 ? "1 interval" : "\(count) intervals"
        case .simplifiedChinese: return "\(count) 个区间"
        }
    }

    func cloudVisibilitySectionTitle() -> String {
        switch self {
        case .english:
            return "Cloud display"
        case .simplifiedChinese:
            return "云端显示"
        }
    }

    func cloudVisibilitySectionDescription() -> String {
        switch self {
        case .english:
            return "Controls how long pure Cloud account visuals stay visible when the latest report is old. Local and Mix accounts are not affected."
        case .simplifiedChinese:
            return "控制纯 Cloud 账号的上报数据变旧后，界面上的曲线、柱图和 cycles 保留多久。本机和 Mix 账号不受影响。"
        }
    }

    func cloudAccountDataSectionTitle() -> String {
        switch self {
        case .english:
            return "Account data"
        case .simplifiedChinese:
            return "账号数据"
        }
    }

    func dataManagementDescriptionText() -> String {
        switch self {
        case .english:
            return "Manage recorded usage data. Credentials and preferences are not deleted."
        case .simplifiedChinese:
            return "管理已记录的用量数据。不会删除凭据和偏好设置。"
        }
    }

    func deleteLocalDataText() -> String {
        switch self {
        case .english:
            return "Delete local data"
        case .simplifiedChinese:
            return "删除本地数据"
        }
    }

    func deleteRemoteDataText() -> String {
        switch self {
        case .english:
            return "Delete all cloud data"
        case .simplifiedChinese:
            return "删除全部云端数据"
        }
    }

    func deleteRemoteAccountDataText() -> String {
        switch self {
        case .english:
            return "Delete account cloud data"
        case .simplifiedChinese:
            return "删除账号云端数据"
        }
    }

    func deleteRemoteAccountDataDescriptionText() -> String {
        switch self {
        case .english:
            return "Select one provider account and remove only that account's Cloud samples. Local data, other accounts, credentials, and preferences are kept."
        case .simplifiedChinese:
            return "选择一个服务商账号，只删除这个账号的 Cloud samples。本地数据、其他账号、凭据和偏好设置都会保留。"
        }
    }

    func noRemoteAccountsText() -> String {
        switch self {
        case .english:
            return "No cloud accounts"
        case .simplifiedChinese:
            return "没有云端账号"
        }
    }

    func refreshText() -> String {
        switch self {
        case .english:
            return "Refresh"
        case .simplifiedChinese:
            return "刷新"
        }
    }

    func deleteLocalDataConfirmationText() -> String {
        switch self {
        case .english:
            return "This removes local usage snapshots, short-window samples, utilization histories, and pending sync queue files. Provider credentials stay in Keychain."
        case .simplifiedChinese:
            return "这会移除本地用量快照、短周期 samples、utilization 历史和待同步队列文件。服务商凭据仍保留在钥匙串。"
        }
    }

    func deleteRemoteDataConfirmationText() -> String {
        switch self {
        case .english:
            return "This deletes all quota samples, device rows, and cloud settings from AI Quota Bar's built-in cloud service."
        case .simplifiedChinese:
            return "这会删除 AI Quota Bar 内置云服务里的全部 quota samples、设备记录和云端设置。"
        }
    }

    func deleteRemoteAccountDataConfirmationText(accountName: String) -> String {
        switch self {
        case .english:
            return "This deletes Cloud quota samples for \(accountName). Local data and other cloud accounts are not deleted."
        case .simplifiedChinese:
            return "这会删除 \(accountName) 的 Cloud quota samples。本地数据和其他云端账号不会被删除。"
        }
    }

    func localDataDeletedText() -> String {
        switch self {
        case .english:
            return "Local usage data deleted."
        case .simplifiedChinese:
            return "本地用量数据已删除。"
        }
    }

    func remoteDataDeletedText(samples: Int, devices: Int) -> String {
        switch self {
        case .english:
            return "Remote data deleted: \(samples) samples, \(devices) devices."
        case .simplifiedChinese:
            return "远程数据已删除：\(samples) 条 samples，\(devices) 个设备。"
        }
    }

    func remoteAccountDataDeletedText(accountName: String, samples: Int) -> String {
        switch self {
        case .english:
            return "Cloud data deleted for \(accountName): \(samples) samples."
        case .simplifiedChinese:
            return "\(accountName) 的云端数据已删除：\(samples) 条 samples。"
        }
    }

    func advancedCleanupSectionTitle() -> String {
        switch self {
        case .english:
            return "Advanced cleanup"
        case .simplifiedChinese:
            return "高级清理"
        }
    }

    func advancedCleanupDisclosureText() -> String {
        switch self {
        case .english:
            return "Show local and all-cloud delete actions"
        case .simplifiedChinese:
            return "显示本地和全量云端删除操作"
        }
    }

    func advancedCleanupDescriptionText() -> String {
        switch self {
        case .english:
            return "These actions affect broad data scopes. They do not delete provider credentials or app preferences."
        case .simplifiedChinese:
            return "这些操作影响范围更大，但不会删除服务商凭据或应用偏好设置。"
        }
    }

    func cloudAccountDeleteUnavailableText() -> String {
        switch self {
        case .english:
            return "Account-level cloud deletion is not available on the current cloud service yet. Try again after the sync service is updated."
        case .simplifiedChinese:
            return "当前云同步服务还不支持按账号删除。等云端服务更新后再试。"
        }
    }

    func cancelText() -> String {
        switch self {
        case .english:
            return "Cancel"
        case .simplifiedChinese:
            return "取消"
        }
    }

    /// 5h 面积图 y 轴节奏参考线右侧标签。
    /// percent 非空时显示"匀速 75%"之类；空时只显示"匀速"。
    func paceGuideLabel(percent: Double?) -> String {
        switch self {
        case .english:
            if let percent { return "Pace \(Int(percent.rounded()))%" }
            return "Pace"
        case .simplifiedChinese:
            if let percent { return "匀速 \(Int(percent.rounded()))%" }
            return "匀速"
        }
    }

    /// 跨周期柱图 X 轴 label：5h 短周期用。
    func modelUtilizationShortCycleLabel() -> String {
        switch self {
        case .english: return "5h cycles"
        case .simplifiedChinese: return "5 小时周期"
        }
    }

    /// 跨周期柱图 X 轴 label：周长周期用。
    func modelUtilizationLongCycleLabel() -> String {
        switch self {
        case .english: return "Week cycles"
        case .simplifiedChinese: return "周周期"
        }
    }

    /// 周期历史模式选择器的标题（General → Behavior 区块里）。
    func utilizationHistoryModeLabel() -> String {
        switch self {
        case .english: return "Cycle history"
        case .simplifiedChinese: return "周期历史"
        }
    }

    /// 周期历史模式的详细说明：明确两种模式的差异，避免再次产生误会。
    func utilizationHistoryModeDescription() -> String {
        switch self {
        case .english:
            return "Controls both 5h and weekly cycle bars. \"Include current\" adds the in-progress cycle as the rightmost bar; \"Completed only\" shows ended cycles only."
        case .simplifiedChinese:
            return "统一控制 5 小时和周周期柱图。「包含当前周期」会把当前进行中的周期作为最右一根柱；「仅已结束周期」只显示已经结束的周期。"
        }
    }

    func utilizationHistoryModeDisplayName(_ mode: UtilizationHistoryMode) -> String {
        switch (self, mode) {
        case (.english, .includeCurrent): return "Include current"
        case (.english, .completedOnly): return "Completed only"
        case (.simplifiedChinese, .includeCurrent): return "包含当前周期"
        case (.simplifiedChinese, .completedOnly): return "仅已结束周期"
        }
    }

    func cloudCurrentWindowVisibilityLimitLabel() -> String {
        switch self {
        case .english: return "Cloud current chart"
        case .simplifiedChinese: return "Cloud 当前图"
        }
    }

    func cloudCurrentWindowVisibilityLimitDescription() -> String {
        switch self {
        case .english:
            return "Hide the current chart for Cloud-only accounts when the latest remote report is older than this value. Mix and local accounts are unaffected."
        case .simplifiedChinese:
            return "纯 Cloud 账号的最新云端上报超过这个时间后，隐藏当前曲线/当前柱图。Mix 和本机账号不受影响。"
        }
    }

    func cloudShortCyclesVisibilityLimitLabel() -> String {
        switch self {
        case .english: return "Cloud 5h cycles"
        case .simplifiedChinese: return "Cloud 5h cycles"
        }
    }

    func cloudShortCyclesVisibilityLimitDescription() -> String {
        switch self {
        case .english:
            return "Hide 5-hour cycle history bars for Cloud-only accounts when the cycle reset time is older than this value."
        case .simplifiedChinese:
            return "纯 Cloud 账号的 5h 历史 cycles，如果对应 reset 时间早于这个范围就隐藏。"
        }
    }

    func cloudWeeklyCyclesVisibilityLimitLabel() -> String {
        switch self {
        case .english: return "Cloud weekly cycles"
        case .simplifiedChinese: return "Cloud weekly cycles"
        }
    }

    func cloudWeeklyCyclesVisibilityLimitDescription() -> String {
        switch self {
        case .english:
            return "Hide weekly cycle history bars for Cloud-only accounts when the cycle reset time is older than this value."
        case .simplifiedChinese:
            return "纯 Cloud 账号的 weekly 历史 cycles，如果对应 reset 时间早于这个范围就隐藏。"
        }
    }

    func cloudDataVisibilityLimitDisplayName(_ limit: CloudDataVisibilityLimit) -> String {
        switch (self, limit) {
        case (.english, .oneHour): return "1 hour"
        case (.english, .fiveHours): return "5 hours"
        case (.english, .oneDay): return "1 day"
        case (.english, .oneWeek): return "1 week"
        case (.english, .never): return "Never hide"
        case (.simplifiedChinese, .oneHour): return "1 小时"
        case (.simplifiedChinese, .fiveHours): return "5 小时"
        case (.simplifiedChinese, .oneDay): return "1 天"
        case (.simplifiedChinese, .oneWeek): return "1 周"
        case (.simplifiedChinese, .never): return "永不隐藏"
        }
    }

    /// 跟 codexbar 的 UsagePaceText 文案完全对齐。
    /// onTrack: if rounded delta is non-zero, still show the small reserve/deficit.
    /// ahead（实际 > 预期，deficit）→ "X% in deficit" / "超额 X%"
    /// behind（实际 < 预期，reserve）→ "X% in reserve" / "余量 X%"
    func paceLabel(stage: UsagePace.Stage, deltaPercent: Double) -> String {
        let deltaValue = Int(abs(deltaPercent).rounded())
        switch self {
        case .english:
            switch stage {
            case .onTrack:
                if deltaValue > 0 {
                    return deltaPercent > 0 ? "\(deltaValue)% in deficit" : "\(deltaValue)% in reserve"
                }
                return "On pace"
            case .slightlyAhead, .ahead, .farAhead:
                return "\(deltaValue)% in deficit"
            case .slightlyBehind, .behind, .farBehind:
                return "\(deltaValue)% in reserve"
            }
        case .simplifiedChinese:
            switch stage {
            case .onTrack:
                if deltaValue > 0 {
                    return deltaPercent > 0 ? "超额 \(deltaValue)%" : "余量 \(deltaValue)%"
                }
                return "节奏正常"
            case .slightlyAhead, .ahead, .farAhead:
                return "超额 \(deltaValue)%"
            case .slightlyBehind, .behind, .farBehind:
                return "余量 \(deltaValue)%"
            }
        }
    }

    func menuBarSectionTitle() -> String {
        switch self {
        case .english: return "Menu bar"
        case .simplifiedChinese: return "菜单栏"
        }
    }

    func menuBarContentLabel() -> String {
        switch self {
        case .english: return "Displayed provider"
        case .simplifiedChinese: return "显示对象"
        }
    }

    func menuBarContentDescription() -> String {
        switch self {
        case .english: return "Automatic shows the provider that needs attention most."
        case .simplifiedChinese: return "自动模式会显示当前最需要关注的服务商。"
        }
    }

    func menuBarContentDisplayName(_ selection: MenuBarContentSelection) -> String {
        switch (self, selection) {
        case (.english, .automatic): return "Automatic"
        case (.english, .codex): return "Codex"
        case (.english, .kimi): return "Kimi"
        case (.english, .miniMax): return "MiniMax"
        case (.simplifiedChinese, .automatic): return "自动"
        case (.simplifiedChinese, .codex): return "Codex"
        case (.simplifiedChinese, .kimi): return "Kimi"
        case (.simplifiedChinese, .miniMax): return "MiniMax"
        }
    }

    func menuBarAppearanceLabel() -> String {
        switch self {
        case .english: return "Appearance"
        case .simplifiedChinese: return "显示方式"
        }
    }

    func menuBarAppearanceDescription() -> String {
        switch self {
        case .english:
            return "For Codex, the outer ring shows Weekly remaining and the split center shows pace."
        case .simplifiedChinese:
            return "Codex 紧凑环的外环显示 Weekly 剩余比例，分半内圆显示消耗节奏。"
        }
    }

    func menuBarAppearanceDisplayName(_ appearance: MenuBarAppearance) -> String {
        switch (self, appearance) {
        case (.english, .detailedText): return "Detailed text"
        case (.english, .compactRing): return "Compact ring"
        case (.simplifiedChinese, .detailedText): return "详细文字"
        case (.simplifiedChinese, .compactRing): return "紧凑环形"
        }
    }

    func menuBarPaceDisplayModeLabel() -> String {
        switch self {
        case .english: return "Pace detail"
        case .simplifiedChinese: return "节奏精度"
        }
    }

    func menuBarPaceDisplayModeDescription() -> String {
        switch self {
        case .english:
            return "Two days of Weekly pace deviation fill a side; choose continuous detail or alerting stages."
        case .simplifiedChinese:
            return "Weekly 节奏偏差两天填满半圆，可选择连续细节或醒目的分级显示。"
        }
    }

    func menuBarPaceDisplayModeDisplayName(_ mode: MenuBarPaceDisplayMode) -> String {
        switch (self, mode) {
        case (.english, .continuous): return "Continuous percentage"
        case (.english, .staged): return "Staged levels"
        case (.simplifiedChinese, .continuous): return "连续百分比"
        case (.simplifiedChinese, .staged): return "节奏分级"
        }
    }

    func menuBarSelfTestTooltip() -> String {
        switch self {
        case .english: return "Refreshing · icon self-test"
        case .simplifiedChinese: return "正在刷新 · 图标自检"
        }
    }

    func menuBarStateText(_ state: MenuBarSnapshotState) -> String {
        switch (self, state) {
        case (.english, .loading): return "loading"
        case (.english, .ready): return "ready"
        case (.english, .unavailable): return "no data"
        case (.english, .failed): return "error"
        case (.simplifiedChinese, .loading): return "加载中"
        case (.simplifiedChinese, .ready): return "正常"
        case (.simplifiedChinese, .unavailable): return "暂无数据"
        case (.simplifiedChinese, .failed): return "获取失败"
        }
    }

    func menuBarStateTooltip(provider: UsageProvider, state: MenuBarSnapshotState) -> String {
        let stateText = menuBarStateText(state)
        switch self {
        case .english: return "\(provider.displayName)\nStatus: \(stateText)"
        case .simplifiedChinese: return "\(provider.displayName)\n状态：\(stateText)"
        }
    }

    func menuBarReadyTooltip(
        provider: UsageProvider,
        modelName: String,
        remainingText: String,
        weeklyRemainingPercent: Double?,
        paceDeltaPercent: Double?,
        resetText: String
    ) -> String {
        let paceText: String
        if let paceDeltaPercent {
            let value = Int(abs(paceDeltaPercent).rounded())
            switch self {
            case .english:
                if value == 0 {
                    paceText = "On pace"
                } else {
                    paceText = paceDeltaPercent > 0 ? "\(value)% in reserve" : "\(value)% in deficit"
                }
            case .simplifiedChinese:
                if value == 0 {
                    paceText = "节奏正常"
                } else {
                    paceText = paceDeltaPercent > 0 ? "余量 \(value)%" : "超额 \(value)%"
                }
            }
        } else {
            paceText = self == .english ? "Pace unavailable" : "暂无节奏数据"
        }

        switch self {
        case .english:
            let weeklyText = weeklyRemainingPercent.map {
                "\nWeekly: \(Int($0.rounded()))% remaining"
            } ?? ""
            return "\(provider.displayName) · \(modelName)\n\(remainingText) remaining\(weeklyText)\n\(paceText)\nResets in \(resetText)"
        case .simplifiedChinese:
            let weeklyText = weeklyRemainingPercent.map {
                "\nWeekly 剩余 \(Int($0.rounded()))%"
            } ?? ""
            return "\(provider.displayName) · \(modelName)\n剩余 \(remainingText)\(weeklyText)\n\(paceText)\n\(resetText) 后重置"
        }
    }

    func codexConnectivityUnavailableTooltip(base: String) -> String {
        switch self {
        case .english:
            return "\(base)\nOpenAI is unreachable"
        case .simplifiedChinese:
            return "\(base)\nOpenAI 当前不可达"
        }
    }
}

enum AppText {
    case preferences
    case preferencesSubtitle
    case tabGeneral
    case tabUsage
    case tabSync
    case tabProviders
    case tabAbout
    case providersTitle
    case systemTitle
    case usageTitle
    case cloudSyncTitle
    case cloudSyncEnabled
    case cloudSyncEnabledDescription
    case cloudSyncOpenData
    case cloudSyncStatusIdle
    case appTitle
    case appDescription
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
    case launchAtLogin
    case launchAtLoginDescription
}
