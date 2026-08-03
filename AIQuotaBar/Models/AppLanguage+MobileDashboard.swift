import Foundation

extension AppLanguage {
    func mobileDashboardTabTitle() -> String {
        switch self {
        case .english: return "Mobile"
        case .simplifiedChinese: return "手机看板"
        }
    }

    func mobileDashboardSectionTitle() -> String {
        switch self {
        case .english: return "Local network dashboard"
        case .simplifiedChinese: return "局域网手机看板"
        }
    }

    func mobileDashboardEnableTitle() -> String {
        switch self {
        case .english: return "Enable the mobile dashboard"
        case .simplifiedChinese: return "启用手机看板"
        }
    }

    func mobileDashboardEnableDescription() -> String {
        switch self {
        case .english:
            return "Starts a read-only local server only while this option is enabled. Devices on the same network can scan the code below to view quota and status."
        case .simplifiedChinese:
            return "仅在开启时启动只读本地服务。同一局域网内的设备可扫描下方二维码，查看配额与状态。"
        }
    }

    func mobileDashboardModelsTitle() -> String {
        switch self {
        case .english: return "Models shown on mobile"
        case .simplifiedChinese: return "手机端显示的模型"
        }
    }

    func mobileDashboardModelsDescription() -> String {
        switch self {
        case .english:
            return "Choose one or two models. The mobile page always keeps both selected models and their quota curves visible."
        case .simplifiedChinese:
            return "请选择一至两个模型。手机页面会始终显示所选模型及其配额曲线。"
        }
    }

    func mobileDashboardModelsSelectedCount(
        _ count: Int,
        maximum: Int
    ) -> String {
        switch self {
        case .english:
            return "\(count) of \(maximum) selected"
        case .simplifiedChinese:
            return "已选择 \(count)/\(maximum)"
        }
    }

    func mobileDashboardModelsLimitReached() -> String {
        switch self {
        case .english: return "Maximum selected"
        case .simplifiedChinese: return "已达上限"
        }
    }

    func mobileDashboardModelsEmpty() -> String {
        switch self {
        case .english:
            return "No quota models are available yet. Refresh usage data, then return here to choose them."
        case .simplifiedChinese:
            return "暂时没有可选的配额模型。刷新用量数据后，可返回此处进行选择。"
        }
    }

    func mobileDashboardDefaultAccount() -> String {
        switch self {
        case .english: return "Default account"
        case .simplifiedChinese: return "默认账户"
        }
    }

    func mobileDashboardUnavailableModelsTitle() -> String {
        switch self {
        case .english: return "Unavailable selections"
        case .simplifiedChinese: return "暂不可用的选择"
        }
    }

    func mobileDashboardUnavailableModelsDescription() -> String {
        switch self {
        case .english:
            return "These saved models are not in the latest quota data. They remain selected in case the account becomes available again."
        case .simplifiedChinese:
            return "以下已保存模型不在最新配额数据中。系统会保留选择，以便对应账户恢复后继续显示。"
        }
    }

    func mobileDashboardUnavailableBadge() -> String {
        switch self {
        case .english: return "Unavailable"
        case .simplifiedChinese: return "不可用"
        }
    }

    func mobileDashboardAtLeastOneModelRequired() -> String {
        switch self {
        case .english:
            return "At least one model must remain selected."
        case .simplifiedChinese:
            return "至少需要保留一个已选模型。"
        }
    }

    func mobileDashboardDeselectModelFirst() -> String {
        switch self {
        case .english:
            return "Deselect another model before selecting this one."
        case .simplifiedChinese:
            return "请先取消选择另一个模型。"
        }
    }

    func mobileDashboardModelSelectionHint() -> String {
        switch self {
        case .english:
            return "Controls whether this model appears on the read-only mobile dashboard."
        case .simplifiedChinese:
            return "控制该模型是否显示在只读手机看板上。"
        }
    }

    func mobileDashboardModelAccessibilityLabel(
        provider: String,
        account: String,
        model: String
    ) -> String {
        switch self {
        case .english:
            return "\(provider), \(account), \(model)"
        case .simplifiedChinese:
            return "\(provider)，\(account)，\(model)"
        }
    }

    func mobileDashboardUnavailableModelAccessibilityHint() -> String {
        switch self {
        case .english:
            return "This saved model is currently unavailable."
        case .simplifiedChinese:
            return "这个已保存的模型当前不可用。"
        }
    }

    func mobileDashboardAccessTitle() -> String {
        switch self {
        case .english: return "Local network access"
        case .simplifiedChinese: return "局域网访问"
        }
    }

    func mobileDashboardAccessCaption() -> String {
        switch self {
        case .english:
            return "The dashboard is read-only and uses plain HTTP on your LAN. Enable it only on a trusted network."
        case .simplifiedChinese:
            return "看板完全只读，并通过局域网明文 HTTP 传输。请仅在可信网络中启用。"
        }
    }

    func mobileDashboardPairingRequiredTitle() -> String {
        switch self {
        case .english: return "Require a pairing code"
        case .simplifiedChinese: return "需要配对码（安全配对）"
        }
    }

    func mobileDashboardPairingRequiredDescription() -> String {
        switch self {
        case .english:
            return "Off by default. When enabled, new devices must enter a random 8-digit code that is valid for 5 minutes. Previously authorized devices remain connected; reset the access key to revoke them."
        case .simplifiedChinese:
            return "默认关闭。开启后，新设备必须输入随机生成且 5 分钟内有效的 8 位配对码。此前已授权的设备仍可继续访问；如需撤销，请重置访问密钥。"
        }
    }

    func mobileDashboardPairingChangeFailed() -> String {
        switch self {
        case .english:
            return "The pairing setting could not be changed. Please try again."
        case .simplifiedChinese:
            return "无法更改配对设置，请重试。"
        }
    }

    func mobileDashboardShareTaskProgressTitle() -> String {
        switch self {
        case .english: return "Share task details and progress"
        case .simplifiedChinese: return "共享任务详情与进度"
        }
    }

    func mobileDashboardShareTaskProgressDescription(
        pairingRequired: Bool
    ) -> String {
        switch (self, pairingRequired) {
        case (.english, true):
            return "Off by default. Shares sanitized task titles, project names, and up to two recent assistant progress lines with manually paired LAN devices. Commands, tool output, full paths, identifiers, reasoning, and detected secrets are never shared."
        case (.simplifiedChinese, true):
            return "默认关闭。开启后，仅向手动配对的局域网设备共享经过安全过滤的任务标题、项目名及最多两条近期助手进度；命令、工具输出、完整路径、标识符、reasoning 和检测到的密钥绝不会共享。"
        case (.english, false):
            return "Requires manual pairing. Enable “Require a pairing code” before sharing sanitized task details and progress."
        case (.simplifiedChinese, false):
            return "需要先开启手动配对。启用“需要配对码”后，才能共享经过安全过滤的任务详情与进度。"
        }
    }

    func mobileDashboardWaitingAddress() -> String {
        switch self {
        case .english:
            return "The server is running, but this Mac has neither a valid Bonjour local hostname nor a private IPv4 address. Connect it to Wi-Fi or Ethernet and check its local hostname."
        case .simplifiedChinese:
            return "服务已运行，但这台 Mac 当前既没有有效的 Bonjour 本地主机名，也没有可用的局域网 IPv4 地址。请检查本地主机名并连接 Wi-Fi 或有线网络。"
        }
    }

    func mobileDashboardStartingStatus() -> String {
        switch self {
        case .english:
            return "Starting the local server and requesting network access…"
        case .simplifiedChinese:
            return "正在启动本地服务并请求局域网访问权限…"
        }
    }

    func mobileDashboardReadyStatus(viewerCount: Int) -> String {
        switch self {
        case .english:
            return viewerCount == 0
                ? "Ready · no devices viewing"
                : "Live · \(viewerCount) \(viewerCount == 1 ? "device" : "devices") viewing"
        case .simplifiedChinese:
            return viewerCount == 0
                ? "已就绪 · 暂无设备查看"
                : "实时中 · \(viewerCount) 台设备正在查看"
        }
    }

    func mobileDashboardOffStatus() -> String {
        switch self {
        case .english:
            return "Off · no port is open and no mobile updates are running."
        case .simplifiedChinese:
            return "已关闭 · 未开放端口，也不会运行移动端实时更新。"
        }
    }

    func mobileDashboardScanTitle() -> String {
        switch self {
        case .english: return "Scan with your phone"
        case .simplifiedChinese: return "使用手机扫码"
        }
    }

    func mobileDashboardScanDescription() -> String {
        switch self {
        case .english:
            return "Keep the Mac and phone on the same trusted network. The page is read-only."
        case .simplifiedChinese:
            return "请让 Mac 和手机处于同一个可信局域网。手机页面完全只读。"
        }
    }

    func mobileDashboardCopyLink() -> String {
        switch self {
        case .english: return "Copy link"
        case .simplifiedChinese: return "复制链接"
        }
    }

    func mobileDashboardStableAddressTitle() -> String {
        switch self {
        case .english: return "Stable Bonjour address"
        case .simplifiedChinese: return "稳定的 Bonjour 地址"
        }
    }

    func mobileDashboardCurrentIPAddressTitle() -> String {
        switch self {
        case .english: return "Current IP address"
        case .simplifiedChinese: return "当前 IP 地址"
        }
    }

    func mobileDashboardIPFallbackTitle() -> String {
        switch self {
        case .english: return "IP fallback"
        case .simplifiedChinese: return "IP 备用链接"
        }
    }

    func mobileDashboardAdditionalIPTitle() -> String {
        switch self {
        case .english: return "Additional IP address"
        case .simplifiedChinese: return "其他 IP 地址"
        }
    }

    func mobileDashboardIPFallbackDescription() -> String {
        switch self {
        case .english:
            return "Use an IP link only if the .local address does not resolve. An IP link may stop working when the Mac changes networks or receives a new address."
        case .simplifiedChinese:
            return "仅在 .local 地址无法解析时使用 IP 链接。Mac 切换网络或取得新地址后，IP 链接可能失效。"
        }
    }

    func mobileDashboardCopyFallbackLink() -> String {
        switch self {
        case .english: return "Copy this IP link"
        case .simplifiedChinese: return "复制这个 IP 链接"
        }
    }

    func mobileDashboardMoreIPAddresses(_ count: Int) -> String {
        switch self {
        case .english:
            return "\(count) more IP \(count == 1 ? "address" : "addresses")"
        case .simplifiedChinese:
            return "另外 \(count) 个 IP 地址"
        }
    }

    func mobileDashboardInstallTitle() -> String {
        switch self {
        case .english: return "Add AI Quota to the Home Screen"
        case .simplifiedChinese: return "将 AI Quota 添加到主屏幕"
        }
    }

    func mobileDashboardManualPairingTitle() -> String {
        switch self {
        case .english: return "Pairing code"
        case .simplifiedChinese: return "配对码"
        }
    }

    func mobileDashboardManualPairingDescription() -> String {
        switch self {
        case .english:
            return "Enter this code on a new phone or web app. It is kept only in memory, expires after 5 minutes, and never appears in a URL."
        case .simplifiedChinese:
            return "请在新手机或网页 App 中输入此代码。代码仅保存在内存中，5 分钟后过期，且不会出现在网址里。"
        }
    }

    func mobileDashboardManualPairingRemaining(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        switch self {
        case .english:
            return String(format: "Expires in %d:%02d", minutes, remainder)
        case .simplifiedChinese:
            return String(format: "%d:%02d 后过期", minutes, remainder)
        }
    }

    func mobileDashboardManualPairingExpired() -> String {
        switch self {
        case .english: return "Expired"
        case .simplifiedChinese: return "已过期"
        }
    }

    func mobileDashboardManualPairingCopy() -> String {
        switch self {
        case .english: return "Copy code"
        case .simplifiedChinese: return "复制代码"
        }
    }

    func mobileDashboardManualPairingCopied() -> String {
        switch self {
        case .english: return "Pairing code copied."
        case .simplifiedChinese: return "配对码已复制。"
        }
    }

    func mobileDashboardManualPairingRefresh() -> String {
        switch self {
        case .english: return "New code"
        case .simplifiedChinese: return "刷新代码"
        }
    }

    func mobileDashboardManualPairingUnavailable() -> String {
        switch self {
        case .english: return "A code will appear when the service is ready."
        case .simplifiedChinese: return "服务就绪后将在此显示配对码。"
        }
    }

    func mobileDashboardInstallDescription() -> String {
        switch self {
        case .english:
            return "iPhone or iPad: open the stable link in Safari, tap Share, choose Add to Home Screen, then enable Open as Web App. Android: open it in Chrome and choose Add to Home screen or Install app. The mobile app is named AI Quota."
        case .simplifiedChinese:
            return "iPhone 或 iPad：用 Safari 打开稳定链接，点按“分享 > 添加到主屏幕”，并开启“作为网页 App 打开”。Android：用 Chrome 打开后选择“添加到主屏幕”或“安装应用”。移动端名称为 AI Quota。"
        }
    }

    func mobileDashboardReinstallNotice() -> String {
        switch self {
        case .english:
            return "If AI Quota was previously added from an IP address, remove that old Home Screen app and add it again from the .local link. Browser storage and sign-in do not move between those addresses."
        case .simplifiedChinese:
            return "如果 AI Quota 之前是从 IP 地址添加的，请删除旧主屏幕应用，再从 .local 链接重新添加。两个地址之间不会迁移浏览器存储和登录状态。"
        }
    }

    func mobileDashboardBonjourUnavailableNotice() -> String {
        switch self {
        case .english:
            return "This Mac does not currently have a valid Bonjour local hostname, so only an IP link is available. Set a local hostname in System Settings > General > Sharing before adding AI Quota to the Home Screen."
        case .simplifiedChinese:
            return "这台 Mac 当前没有有效的 Bonjour 本地主机名，因此只能使用 IP 链接。请先在“系统设置 > 通用 > 共享”中设置本地主机名，再将 AI Quota 添加到主屏幕。"
        }
    }

    func mobileDashboardLinkCopied() -> String {
        switch self {
        case .english: return "Link copied."
        case .simplifiedChinese: return "链接已复制。"
        }
    }

    func mobileDashboardResetLink() -> String {
        switch self {
        case .english: return "Reset access key"
        case .simplifiedChinese: return "重置访问密钥"
        }
    }

    func mobileDashboardResetLinkDescription() -> String {
        switch self {
        case .english:
            return "Creates a new access key and immediately disconnects devices using the previous link."
        case .simplifiedChinese:
            return "生成新的访问密钥，并立即断开仍在使用旧链接的设备。"
        }
    }

    func mobileDashboardPrivacyTitle() -> String {
        switch self {
        case .english: return "Mask accounts on mobile"
        case .simplifiedChinese: return "手机端账号脱敏"
        }
    }

    func mobileDashboardPrivacyDescription() -> String {
        switch self {
        case .english:
            return "On by default. If disabled, devices on your local network can see complete account names. Quota and plan details remain visible either way."
        case .simplifiedChinese:
            return "默认开启。关闭脱敏后，局域网设备可看到完整账号。无论是否脱敏，配额与套餐信息都会显示。"
        }
    }

    func mobileDashboardColorSchemeTitle() -> String {
        switch self {
        case .english: return "Dashboard appearance"
        case .simplifiedChinese: return "看板界面外观"
        }
    }

    func mobileDashboardColorSchemeDescription() -> String {
        switch self {
        case .english:
            return "Applies to every connected dashboard and updates open pages immediately. Automatic follows each device or browser and is the default."
        case .simplifiedChinese:
            return "应用于所有已连接的看板，并立即更新已打开的页面。自动模式会分别跟随每台设备或浏览器，且为默认选项。"
        }
    }

    func mobileDashboardAutomaticColorScheme() -> String {
        switch self {
        case .english: return "Automatic"
        case .simplifiedChinese: return "自动"
        }
    }

    func mobileDashboardDarkColorScheme() -> String {
        switch self {
        case .english: return "Dark"
        case .simplifiedChinese: return "暗色"
        }
    }

    func mobileDashboardLightColorScheme() -> String {
        switch self {
        case .english: return "Light"
        case .simplifiedChinese: return "亮色"
        }
    }

    func mobileDashboardIdleBlackoutMarqueeTitle() -> String {
        switch self {
        case .english: return "Full-screen marquee while idle"
        case .simplifiedChinese: return "空闲时仅显示全屏跑马灯"
        }
    }

    func mobileDashboardIdleBlackoutMarqueeDescription() -> String {
        switch self {
        case .english:
            return "On confirmed idle, replaces the dashboard with a moving status marquee on pure black. Stale, unavailable, and offline states never use this mode."
        case .simplifiedChinese:
            return "仅在确认空闲时，以纯黑背景的动态状态跑马灯替代看板；状态过期、不可用或离线时绝不会进入此模式。"
        }
    }

    func mobileDashboardOLEDTitle() -> String {
        switch self {
        case .english: return "OLED protection"
        case .simplifiedChinese: return "OLED 防烧屏保护"
        }
    }

    func mobileDashboardOLEDDescription() -> String {
        switch self {
        case .english:
            return "Dims after 30 seconds without input and gently shifts static content. The page never prevents the phone from sleeping."
        case .simplifiedChinese:
            return "无操作 30 秒后自动降亮，并轻微移动静态内容。页面不会阻止手机自动锁屏。"
        }
    }

    func mobileDashboardExperimentalWakeMediaTitle() -> String {
        switch self {
        case .english: return "Experimental screen-awake media"
        case .simplifiedChinese: return "实验性媒体保亮"
        }
    }

    func mobileDashboardExperimentalWakeMediaDescription() -> String {
        switch self {
        case .english:
            return "Experimental: this cannot guarantee that the phone will stay awake and may use more battery. After enabling it here, tap Enable on the phone to start it."
        case .simplifiedChinese:
            return "实验性功能：无法保证手机持续亮屏，并可能增加耗电。在此开启后，仍需在手机页面点按“启用”才能开始。"
        }
    }

    func mobileDashboardActivityBackgroundEffectTitle() -> String {
        switch self {
        case .english: return "Activity background effect"
        case .simplifiedChinese: return "Activity 区块背景效果"
        }
    }

    func mobileDashboardActivityBackgroundEffectDescription() -> String {
        switch self {
        case .english:
            return "Changes only the animated background in the Codex Activity card. Task status and every other dashboard section stay unchanged."
        case .simplifiedChinese:
            return "仅切换 Codex Activity 卡片内的动态背景；任务状态与看板其他区块不会改变。"
        }
    }

    func mobileDashboardGrainyDigitalRainEffect() -> String {
        switch self {
        case .english: return "Grainy digital rain"
        case .simplifiedChinese: return "颗粒数字雨"
        }
    }

    func mobileDashboardDotWavesEffect() -> String {
        switch self {
        case .english: return "Dot waves"
        case .simplifiedChinese: return "点阵波浪"
        }
    }

    func mobileDashboardTaskTelemetryMarqueeEffect() -> String {
        switch self {
        case .english: return "Task telemetry barrage"
        case .simplifiedChinese: return "任务信息弹幕"
        }
    }

    func mobileDashboardTaskTelemetryFieldsTitle() -> String {
        switch self {
        case .english: return "Task barrage fields"
        case .simplifiedChinese: return "任务弹幕显示字段"
        }
    }

    func mobileDashboardTaskTelemetryFieldsDescription() -> String {
        switch self {
        case .english:
            return "Choose exactly which verified Codex fields appear in each task’s barrage row. Title, project, Git branch, subtask names, and progress also require “Share task details and progress.”"
        case .simplifiedChinese:
            return "勾选每个任务弹幕行需要显示的 Codex 真实可读字段。任务标题、项目名称、Git 分支、子任务名称和最新进度还需要开启“共享任务详情与进度”。"
        }
    }

    func mobileDashboardTaskTelemetryFieldName(
        _ field: MobileDashboardTaskTelemetryField
    ) -> String {
        switch (self, field) {
        case (.english, .title): return "Task title"
        case (.simplifiedChinese, .title): return "任务标题"
        case (.english, .state): return "Working state"
        case (.simplifiedChinese, .state): return "工作状态"
        case (.english, .phase): return "Current phase"
        case (.simplifiedChinese, .phase): return "当前阶段"
        case (.english, .project): return "Project name"
        case (.simplifiedChinese, .project): return "项目名称"
        case (.english, .gitBranch): return "Git branch"
        case (.simplifiedChinese, .gitBranch): return "Git 分支"
        case (.english, .source): return "Task source"
        case (.simplifiedChinese, .source): return "任务来源"
        case (.english, .model): return "Model"
        case (.simplifiedChinese, .model): return "模型"
        case (.english, .modelProvider): return "Model provider"
        case (.simplifiedChinese, .modelProvider): return "模型提供商"
        case (.english, .reasoningEffort): return "Reasoning effort"
        case (.simplifiedChinese, .reasoningEffort): return "推理强度"
        case (.english, .sandboxPolicy): return "Sandbox policy"
        case (.simplifiedChinese, .sandboxPolicy): return "沙箱策略"
        case (.english, .approvalMode): return "Approval mode"
        case (.simplifiedChinese, .approvalMode): return "审批模式"
        case (.english, .tokensUsed): return "Tokens used"
        case (.simplifiedChinese, .tokensUsed): return "Token 用量"
        case (.english, .activeSubtasks): return "Active subtasks"
        case (.simplifiedChinese, .activeSubtasks): return "活跃子任务"
        case (.english, .subtaskNames): return "Subtask names"
        case (.simplifiedChinese, .subtaskNames): return "子任务名称"
        case (.english, .createdAt): return "Task created"
        case (.simplifiedChinese, .createdAt): return "任务创建时间"
        case (.english, .startedAt): return "Start time"
        case (.simplifiedChinese, .startedAt): return "开始时间"
        case (.english, .elapsed): return "Elapsed time"
        case (.simplifiedChinese, .elapsed): return "持续时间"
        case (.english, .lastUpdated): return "Last updated"
        case (.simplifiedChinese, .lastUpdated): return "最近更新"
        case (.english, .cliVersion): return "Codex CLI version"
        case (.simplifiedChinese, .cliVersion): return "Codex CLI 版本"
        case (.english, .tool): return "Tool and status"
        case (.simplifiedChinese, .tool): return "工具与状态"
        case (.english, .recentEvent): return "Recent event"
        case (.simplifiedChinese, .recentEvent): return "最近事件"
        case (.english, .progress): return "Latest progress"
        case (.simplifiedChinese, .progress): return "最新进度"
        }
    }

    func mobileDashboardTroubleshootingTitle() -> String {
        switch self {
        case .english: return "If the phone cannot connect"
        case .simplifiedChinese: return "手机无法连接时"
        }
    }

    func mobileDashboardTroubleshootingDescription() -> String {
        switch self {
        case .english:
            return "Allow AI Quota Bar in System Settings > Privacy & Security > Local Network, and check that the macOS firewall permits incoming connections."
        case .simplifiedChinese:
            return "请在“系统设置 > 隐私与安全性 > 本地网络”中允许 AI Quota Bar，并检查 macOS 防火墙是否允许传入连接。"
        }
    }
}
