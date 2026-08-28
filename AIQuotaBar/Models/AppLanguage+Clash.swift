import Foundation

extension AppLanguage {
    func clashRoutesTitle() -> String {
        switch self {
        case .english: return "OpenAI routes"
        case .simplifiedChinese: return "OpenAI 线路"
        }
    }

    func clashSearchPlaceholder() -> String {
        switch self {
        case .english: return "Country, flag, node name…"
        case .simplifiedChinese: return "国家、旗帜或线路名称…"
        }
    }

    func clashRegexToggle() -> String {
        switch self {
        case .english: return "Regex"
        case .simplifiedChinese: return "正则"
        }
    }

    func clashRegexHelp() -> String {
        switch self {
        case .english: return "Match the original Clash route name with a case-insensitive regular expression."
        case .simplifiedChinese: return "使用忽略大小写的正则表达式匹配 Clash 原始线路名称。"
        }
    }

    func clashEditFilter() -> String {
        switch self {
        case .english: return "Edit"
        case .simplifiedChinese: return "编辑"
        }
    }

    func clashFinishEditingFilter() -> String {
        switch self {
        case .english: return "Done"
        case .simplifiedChinese: return "完成"
        }
    }

    func clashAutoSelectBest() -> String {
        switch self {
        case .english: return "On connection failure, switch to the fastest match"
        case .simplifiedChinese: return "连接异常时，自动切换到筛选结果中的最快线路"
        }
    }

    func clashAutoSelectNeedsFilter() -> String {
        switch self {
        case .english: return "Enter a filter before automatic recovery can run."
        case .simplifiedChinese: return "输入筛选条件后，自动恢复才会生效。"
        }
    }

    func clashTestingRoutes() -> String {
        switch self {
        case .english: return "Testing routes…"
        case .simplifiedChinese: return "正在测速…"
        }
    }

    func clashTestAgain() -> String {
        switch self {
        case .english: return "Test again"
        case .simplifiedChinese: return "重新测速"
        }
    }

    func clashLoading() -> String {
        switch self {
        case .english: return "Connecting to Clash…"
        case .simplifiedChinese: return "正在连接 Clash…"
        }
    }

    func clashNoMatches() -> String {
        switch self {
        case .english: return "No routes match this filter."
        case .simplifiedChinese: return "没有线路符合当前筛选条件。"
        }
    }

    func clashNoMatchesHelp() -> String {
        switch self {
        case .english: return "Try another country alias or adjust the regular expression."
        case .simplifiedChinese: return "可以换一个国家别名，或调整正则表达式。"
        }
    }

    func clashUnavailableTitle() -> String {
        switch self {
        case .english: return "Clash control unavailable"
        case .simplifiedChinese: return "无法控制 Clash"
        }
    }

    func clashUnavailableHelp() -> String {
        switch self {
        case .english: return "Start Clash and enable its local External Controller, then try again."
        case .simplifiedChinese: return "请启动 Clash 并开启本机 External Controller，然后重试。"
        }
    }

    func clashRetry() -> String {
        switch self {
        case .english: return "Retry"
        case .simplifiedChinese: return "重试"
        }
    }

    func clashCurrentRoute() -> String {
        switch self {
        case .english: return "Current"
        case .simplifiedChinese: return "当前"
        }
    }

    func clashRecentRouteSwitches() -> String {
        switch self {
        case .english: return "Recent switches"
        case .simplifiedChinese: return "最近切换"
        }
    }

    func clashNoRouteSwitchHistory() -> String {
        switch self {
        case .english: return "No switch records yet"
        case .simplifiedChinese: return "暂无切换记录"
        }
    }

    func clashDelayUnavailable() -> String {
        switch self {
        case .english: return "Timeout"
        case .simplifiedChinese: return "超时"
        }
    }

    func clashRouteCount(visible: Int, total: Int) -> String {
        switch self {
        case .english: return "\(visible) of \(total) routes"
        case .simplifiedChinese: return "\(visible) / \(total) 条线路"
        }
    }

    func clashRegexError(_ message: String) -> String {
        switch self {
        case .english: return "Invalid regular expression: \(message)"
        case .simplifiedChinese: return "正则表达式无效：\(message)"
        }
    }

    func clashReadyStatus(groupName: String) -> String {
        switch self {
        case .english: return "Using \(groupName)"
        case .simplifiedChinese: return "使用策略组 \(groupName)"
        }
    }

    func clashSpeedTestFinished() -> String {
        switch self {
        case .english: return "Latency test finished."
        case .simplifiedChinese: return "测速完成。"
        }
    }

    func clashSelectedRoute(_ routeName: String) -> String {
        switch self {
        case .english: return "Switched to \(routeName)."
        case .simplifiedChinese: return "已切换到 \(routeName)。"
        }
    }

    func clashAlreadyFastest(_ routeName: String) -> String {
        switch self {
        case .english: return "\(routeName) is already the fastest match."
        case .simplifiedChinese: return "\(routeName) 已是筛选结果中的最快线路。"
        }
    }

    func clashSpeedTestFailed(_ message: String) -> String {
        switch self {
        case .english: return "Latency test failed: \(message)"
        case .simplifiedChinese: return "测速失败：\(message)"
        }
    }

    func clashSelectionFailed(_ message: String) -> String {
        switch self {
        case .english: return "Route switch failed: \(message)"
        case .simplifiedChinese: return "线路切换失败：\(message)"
        }
    }

    func clashRecoveryFailed() -> String {
        switch self {
        case .english: return "Automatic recovery could not restore the OpenAI connection."
        case .simplifiedChinese: return "自动恢复未能重新连接 OpenAI，请手动选择线路。"
        }
    }

    func clashRecoveryNotificationTitle() -> String {
        switch self {
        case .english: return "OpenAI route recovered"
        case .simplifiedChinese: return "OpenAI 线路已自动恢复"
        }
    }

    func clashRecoveryNotificationBody(
        from previousRoute: String,
        to selectedRoute: String,
        delay: Int
    ) -> String {
        switch self {
        case .english:
            return "Connection issue detected. Switched from \(previousRoute) to \(selectedRoute) (\(delay) ms)."
        case .simplifiedChinese:
            return "检测到连接异常，已从「\(previousRoute)」切换到「\(selectedRoute)」（\(delay) ms）。"
        }
    }

    func clashConnectionsTitle() -> String {
        switch self {
        case .english: return "OpenAI connections"
        case .simplifiedChinese: return "OpenAI 连接"
        }
    }

    func clashConnectionsLive() -> String {
        switch self {
        case .english: return "Live · 1 second"
        case .simplifiedChinese: return "实时 · 1 秒"
        }
    }

    func clashConnectionsBackground() -> String {
        switch self {
        case .english: return "Background · 1 minute"
        case .simplifiedChinese: return "后台 · 1 分钟"
        }
    }

    func clashConnectionsFixedFilter() -> String {
        switch self {
        case .english: return "Active only · openai.com | chatgpt.com"
        case .simplifiedChinese: return "仅活跃连接 · openai.com | chatgpt.com"
        }
    }

    func clashConnectionsLoading() -> String {
        switch self {
        case .english: return "Reading Clash connections…"
        case .simplifiedChinese: return "正在读取 Clash 连接…"
        }
    }

    func clashConnectionsActivityTitle() -> String {
        switch self {
        case .english: return "Active connection history"
        case .simplifiedChinese: return "活跃连接时序"
        }
    }

    func clashConnectionAgeNew() -> String {
        switch self {
        case .english: return "New"
        case .simplifiedChinese: return "新"
        }
    }

    func clashConnectionAgeLong() -> String {
        switch self {
        case .english: return "Old"
        case .simplifiedChinese: return "旧"
        }
    }

    func clashRouteSwitchJustNow() -> String {
        switch self {
        case .english: return "now"
        case .simplifiedChinese: return "刚刚"
        }
    }

    func clashRouteSwitchMinutesAgo(_ minutes: Int) -> String {
        switch self {
        case .english: return "\(minutes)m ago"
        case .simplifiedChinese: return "\(minutes) 分钟前"
        }
    }

    func clashActiveConnections() -> String {
        switch self {
        case .english: return "Active connections"
        case .simplifiedChinese: return "活跃连接"
        }
    }

    func clashActiveConnectionCount(_ count: Int) -> String {
        switch self {
        case .english: return "\(count) active"
        case .simplifiedChinese: return "\(count) 个活跃"
        }
    }

    func clashNoActiveConnections() -> String {
        switch self {
        case .english: return "No active OpenAI connections"
        case .simplifiedChinese: return "当前没有活跃的 OpenAI 连接"
        }
    }

    func clashNoActiveConnectionsHelp() -> String {
        switch self {
        case .english: return "Only openai.com and chatgpt.com are monitored."
        case .simplifiedChinese: return "这里只监测 openai.com 与 chatgpt.com。"
        }
    }

    func clashDownloadSpeed() -> String {
        switch self {
        case .english: return "Download"
        case .simplifiedChinese: return "总下载"
        }
    }

    func clashUploadSpeed() -> String {
        switch self {
        case .english: return "Upload"
        case .simplifiedChinese: return "总上传"
        }
    }

    func clashConnectionCount() -> String {
        switch self {
        case .english: return "Connections"
        case .simplifiedChinese: return "连接数"
        }
    }

    func clashUnknownProcess() -> String {
        switch self {
        case .english: return "Unknown process"
        case .simplifiedChinese: return "未知进程"
        }
    }

    func clashConnectionsReadOnly() -> String {
        switch self {
        case .english: return "Read-only monitoring"
        case .simplifiedChinese: return "只读监测"
        }
    }

    func clashErrorMessage(_ error: Error) -> String {
        guard let clashError = error as? ClashIntegrationError else {
            return error.localizedDescription
        }

        switch clashError {
        case .configurationNotFound:
            return self == .english
                ? "No supported Clash configuration was found."
                : "未找到受支持的 Clash 配置。"
        case .externalControllerDisabled:
            return self == .english
                ? "The Clash External Controller is disabled."
                : "Clash External Controller 尚未开启。"
        case .unsafeControllerHost:
            return self == .english
                ? "Only a local Clash controller is supported."
                : "仅支持连接本机 Clash 控制器。"
        case .invalidControllerAddress:
            return self == .english
                ? "The Clash controller address is invalid."
                : "Clash 控制器地址无效。"
        case .controllerUnavailable:
            return self == .english
                ? "The Clash controller did not respond."
                : "Clash 控制器没有响应。"
        case .incompatibleResponse:
            return self == .english
                ? "The Clash response format is not supported."
                : "当前 Clash 返回格式不受支持。"
        case .strategyGroupNotFound:
            return self == .english
                ? "No switchable strategy group for OpenAI was found."
                : "没有找到可切换的 OpenAI 策略组。"
        case let .apiFailure(statusCode, message):
            return self == .english
                ? "Clash API \(statusCode): \(message)"
                : "Clash API \(statusCode)：\(message)"
        }
    }
}
