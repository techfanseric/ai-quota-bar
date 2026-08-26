import Foundation

extension AppLanguage {
    func sleepProtectionSectionTitle() -> String {
        switch self {
        case .english: return "AI task protection"
        case .simplifiedChinese: return "AI 任务保护"
        }
    }

    func sleepProtectionEnabledTitle() -> String {
        switch self {
        case .english: return "Protect the Mac while AI tasks are working"
        case .simplifiedChinese: return "AI 任务工作时保护 Mac"
        }
    }

    func sleepProtectionEnabledDescription() -> String {
        switch self {
        case .english:
            return "Prevents idle sleep only during active Codex or Kimi tasks. All assertions are released when the tasks finish or AI Quota Bar exits."
        case .simplifiedChinese:
            return "仅在 Codex 或 Kimi 任务进行期间阻止空闲休眠；任务结束或退出 AI Quota Bar 时会立即释放全部系统断言。"
        }
    }

    func keepDisplayAwakeTitle() -> String {
        switch self {
        case .english: return "Keep the display on"
        case .simplifiedChinese: return "保持显示器开启"
        }
    }

    func keepDisplayAwakeDescription() -> String {
        switch self {
        case .english:
            return "Prevents automatic display sleep while a protected AI task is working. Manually locking the Mac is still respected."
        case .simplifiedChinese:
            return "受保护的 AI 任务工作时阻止显示器因空闲而关闭；手动锁定 Mac 时仍尊重系统锁屏行为。"
        }
    }

    func preventScreenSaverTitle() -> String {
        switch self {
        case .english: return "Prevent the screen saver"
        case .simplifiedChinese: return "阻止自动屏保"
        }
    }

    func preventScreenSaverDescription() -> String {
        switch self {
        case .english:
            return "Refreshes macOS user-activity assertions while a task is active so the screen saver does not start automatically."
        case .simplifiedChinese:
            return "任务进行时持续刷新 macOS 用户活动断言，避免系统因空闲自动进入屏保。"
        }
    }

    func allowClosedLidTitle() -> String {
        switch self {
        case .english: return "Allow AI tasks to continue with the lid closed"
        case .simplifiedChinese: return "允许 AI 任务在合盖后继续工作"
        }
    }

    func allowClosedLidDescription() -> String {
        switch self {
        case .english:
            return "Optional. Uses a macOS-approved privileged helper only during active tasks. It restores the previous setting on completion, disconnect, timeout, low battery, or high temperature."
        case .simplifiedChinese:
            return "可选。仅在任务进行时通过 macOS 授权的特权辅助进程生效；任务完成、连接中断、心跳超时、低电量或高温时都会恢复原设置。"
        }
    }

    func closedLidDisabledStatus() -> String {
        switch self {
        case .english: return "Off · lid-close sleep follows the normal macOS policy"
        case .simplifiedChinese: return "已关闭 · 合盖休眠遵循 macOS 原有策略"
        }
    }

    func closedLidReadyStatus() -> String {
        switch self {
        case .english: return "Authorized · waiting for an active AI task"
        case .simplifiedChinese: return "已授权 · 正在等待 AI 任务"
        }
    }

    func closedLidActiveStatus() -> String {
        switch self {
        case .english: return "Active · closed-lid lease is being renewed every 30 seconds"
        case .simplifiedChinese: return "已生效 · 每 30 秒续期一次合盖工作租约"
        }
    }

    func closedLidRequiresApprovalStatus() -> String {
        switch self {
        case .english:
            return "Administrator approval is required in System Settings > Login Items."
        case .simplifiedChinese:
            return "需要在“系统设置 > 登录项”中完成管理员授权。"
        }
    }

    func closedLidLowBatteryStatus(_ percentage: Int) -> String {
        switch self {
        case .english:
            return "Paused at \(percentage)% battery; closed-lid mode requires at least 20% unless connected to power."
        case .simplifiedChinese:
            return "电量仅 \(percentage)%，合盖模式已暂停；未接电源时至少需要 20% 电量。"
        }
    }

    func closedLidThermalStatus() -> String {
        switch self {
        case .english: return "Paused because macOS reports serious thermal pressure."
        case .simplifiedChinese: return "macOS 报告严重温度压力，合盖模式已暂停。"
        }
    }

    func closedLidMaximumDurationStatus() -> String {
        switch self {
        case .english:
            return "Paused after the 12-hour closed-lid safety limit. Open-lid protection remains active."
        case .simplifiedChinese:
            return "已达到 12 小时合盖安全上限；开盖防休眠仍继续生效。"
        }
    }

    func closedLidUnavailableStatus(_ message: String) -> String {
        switch self {
        case .english: return "Closed-lid mode unavailable: \(message)"
        case .simplifiedChinese: return "合盖模式不可用：\(message)"
        }
    }

    func openApprovalSettingsTitle() -> String {
        switch self {
        case .english: return "Open Settings"
        case .simplifiedChinese: return "打开系统设置"
        }
    }

    func sleepProtectionStatusTitle() -> String {
        switch self {
        case .english: return "Current status"
        case .simplifiedChinese: return "当前状态"
        }
    }

    func sleepProtectionIdleStatus() -> String {
        switch self {
        case .english: return "Ready · normal macOS power policy"
        case .simplifiedChinese: return "已就绪 · 当前使用 macOS 原有电源策略"
        }
    }

    func sleepProtectionActiveStatus(turnCount: Int) -> String {
        switch self {
        case .english:
            return "Protecting \(turnCount) active AI \(turnCount == 1 ? "task" : "tasks")"
        case .simplifiedChinese:
            return "正在保护 \(turnCount) 个进行中的 AI 任务"
        }
    }

    func sleepProtectionFailedStatus(_ message: String) -> String {
        switch self {
        case .english: return "Power protection failed: \(message)"
        case .simplifiedChinese: return "电源保护失败：\(message)"
        }
    }

    func codexHooksStatusTitle() -> String {
        switch self {
        case .english: return "Codex hooks"
        case .simplifiedChinese: return "Codex Hooks"
        }
    }

    func codexHooksInstalledStatus() -> String {
        switch self {
        case .english:
            return "Installed. Codex may ask you to review and trust this hook definition once."
        case .simplifiedChinese:
            return "已安装。Codex 可能会要求你首次审查并信任这组 Hook 定义。"
        }
    }

    func codexHooksMissingStatus() -> String {
        switch self {
        case .english:
            return "The bundled hook helper is missing. Reinstall or rebuild the app."
        case .simplifiedChinese:
            return "应用内缺少 Hook 辅助程序，请重新安装或构建应用。"
        }
    }

    func codexHooksNotCheckedStatus() -> String {
        switch self {
        case .english: return "Hook installation has not been checked."
        case .simplifiedChinese: return "尚未检查 Hook 安装状态。"
        }
    }

    func codexHooksFailedStatus(_ message: String) -> String {
        switch self {
        case .english: return "Could not install Codex hooks: \(message)"
        case .simplifiedChinese: return "无法安装 Codex Hooks：\(message)"
        }
    }

    func retryHookInstallationTitle() -> String {
        switch self {
        case .english: return "Retry"
        case .simplifiedChinese: return "重试"
        }
    }

    func keepDisplayAwakeCompactTitle() -> String {
        switch self {
        case .english: return "Keep display on"
        case .simplifiedChinese: return "保持显示器开启"
        }
    }

    func preventScreenSaverCompactTitle() -> String {
        switch self {
        case .english: return "Block screen saver"
        case .simplifiedChinese: return "阻止自动屏保"
        }
    }

    func allowClosedLidCompactTitle() -> String {
        switch self {
        case .english: return "Continue with lid closed"
        case .simplifiedChinese: return "合盖后继续工作"
        }
    }

    func sleepProtectionCompactOffStatus() -> String {
        switch self {
        case .english: return "Off · normal macOS power policy"
        case .simplifiedChinese: return "已关闭 · 使用 macOS 原有电源策略"
        }
    }

    func sleepProtectionCompactReadyStatus(
        providers: Set<UsageProvider>
    ) -> String {
        let names = taskProtectionProviderNames(providers)
        switch self {
        case .english:
            return names.isEmpty
                ? "Ready · no local AI provider configured"
                : "Ready · waiting for \(names)"
        case .simplifiedChinese:
            return names.isEmpty
                ? "已就绪 · 尚未配置本地 AI 服务商"
                : "已就绪 · 正在等待 \(names) 任务"
        }
    }

    func sleepProtectionCompactActiveStatus(
        turnCount: Int,
        providers: Set<UsageProvider>
    ) -> String {
        let names = taskProtectionProviderNames(providers)
        switch self {
        case .english:
            return "Active · \(turnCount) \(names) \(turnCount == 1 ? "task" : "tasks")"
        case .simplifiedChinese:
            return "保护中 · \(turnCount) 个 \(names) 任务"
        }
    }

    private func taskProtectionProviderNames(
        _ providers: Set<UsageProvider>
    ) -> String {
        let names = [UsageProvider.codex, .kimi]
            .filter { providers.contains($0) }
            .map(\.displayName)
        switch (self, names.count) {
        case (_, 0): return "AI"
        case (_, 1): return names[0]
        case (.english, _): return names.joined(separator: " and ")
        case (.simplifiedChinese, _): return names.joined(separator: " 与 ")
        }
    }

    func codexHooksMissingCompactStatus() -> String {
        switch self {
        case .english: return "Hook helper missing · retry after reinstalling"
        case .simplifiedChinese: return "缺少 Hook 辅助程序 · 请重装后重试"
        }
    }

    func codexHooksFailedCompactStatus() -> String {
        switch self {
        case .english: return "Codex hooks need attention"
        case .simplifiedChinese: return "Codex Hooks 需要处理"
        }
    }

    func closedLidCompactOffStatus() -> String {
        switch self {
        case .english: return "Off · normal lid-close sleep"
        case .simplifiedChinese: return "已关闭 · 合盖后正常休眠"
        }
    }

    func closedLidCompactReadyStatus() -> String {
        switch self {
        case .english: return "Authorized · waiting for a task"
        case .simplifiedChinese: return "已授权 · 正在等待任务"
        }
    }

    func closedLidCompactInstallationRequiredStatus() -> String {
        switch self {
        case .english: return "Setup required · install helper"
        case .simplifiedChinese: return "需要设置 · 请安装辅助程序"
        }
    }

    func closedLidCompactInstallingStatus() -> String {
        switch self {
        case .english: return "Installing privileged helper…"
        case .simplifiedChinese: return "正在安装特权辅助程序…"
        }
    }

    func closedLidCompactCheckingStatus() -> String {
        switch self {
        case .english: return "Checking helper connection…"
        case .simplifiedChinese: return "正在检查辅助程序连接…"
        }
    }

    func closedLidCompactActiveStatus() -> String {
        switch self {
        case .english: return "Active · lease renews every 30 seconds"
        case .simplifiedChinese: return "已生效 · 每 30 秒续期"
        }
    }

    func closedLidCompactApprovalStatus() -> String {
        switch self {
        case .english: return "Administrator approval required"
        case .simplifiedChinese: return "需要管理员授权"
        }
    }

    func closedLidCompactLowBatteryStatus(_ percentage: Int) -> String {
        switch self {
        case .english: return "Paused · battery at \(percentage)%"
        case .simplifiedChinese: return "已暂停 · 电量 \(percentage)%"
        }
    }

    func closedLidCompactThermalStatus() -> String {
        switch self {
        case .english: return "Paused · high temperature"
        case .simplifiedChinese: return "已暂停 · 温度过高"
        }
    }

    func closedLidCompactMaximumDurationStatus() -> String {
        switch self {
        case .english: return "Paused · 12-hour safety limit"
        case .simplifiedChinese: return "已暂停 · 达到 12 小时安全上限"
        }
    }

    func closedLidCompactUnavailableStatus(
        _ message: String
    ) -> String {
        switch self {
        case .english: return "Helper error · \(message)"
        case .simplifiedChinese: return "辅助程序错误 · \(message)"
        }
    }

    func installSleepHelperCompactTitle() -> String {
        switch self {
        case .english: return "Install"
        case .simplifiedChinese: return "安装"
        }
    }

    func retrySleepHelperCompactTitle() -> String {
        switch self {
        case .english: return "Retry"
        case .simplifiedChinese: return "重试"
        }
    }

    func openApprovalSettingsCompactTitle() -> String {
        switch self {
        case .english: return "Approve"
        case .simplifiedChinese: return "授权"
        }
    }
}
