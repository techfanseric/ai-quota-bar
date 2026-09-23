import AppKit

/// 供应商与其桌面应用的对应关系，供「跟随运行中的应用」显示开关使用。
/// 匹配规则：bundle ID 精确匹配 + 可选的 bundle ID 片段包含 +
/// 进程名精确匹配（统一小写）。
struct ProviderAppMatcher: Sendable, Equatable {
    let bundleIdentifiers: Set<String>
    let bundleIdentifierFragment: String?
    let processNames: Set<String>

    func matches(bundleIdentifier: String?, processName: String?) -> Bool {
        if let bundleIdentifier = bundleIdentifier?.lowercased() {
            if bundleIdentifiers.contains(bundleIdentifier) { return true }
            if let fragment = bundleIdentifierFragment,
               bundleIdentifier.contains(fragment) {
                return true
            }
        }
        let name = (processName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return processNames.contains(name)
    }

    func matches(_ app: NSRunningApplication) -> Bool {
        matches(
            bundleIdentifier: app.bundleIdentifier,
            processName: app.localizedName ?? app.executableURL?.lastPathComponent)
    }
}

extension UsageProvider {
    /// 打开哪个桌面应用时，菜单栏与左键菜单应显示这家供应商。
    var companionAppMatcher: ProviderAppMatcher {
        switch self {
        case .codex:
            // ChatGPT.app（内置 Codex）与独立 Codex 入口。
            return ProviderAppMatcher(
                bundleIdentifiers: [
                    "com.openai.codex",
                    "com.openai.chatgpt.codex",
                    "com.openai.chat",
                ],
                bundleIdentifierFragment: "codex",
                processNames: ["chatgpt", "codex"])
        case .kimi:
            // Kimi.app；KimiCU 等后台组件不计入。
            return ProviderAppMatcher(
                bundleIdentifiers: ["com.moonshot.kimichat"],
                bundleIdentifierFragment: nil,
                processNames: ["kimi"])
        case .miniMax:
            // MiniMax Code（国内版与国际版 bundle ID）。
            return ProviderAppMatcher(
                bundleIdentifiers: ["com.minimax.agent.cn", "com.minimax.agent"],
                bundleIdentifierFragment: nil,
                processNames: ["minimax code", "minimax"])
        case .glm:
            // ZCode（z.ai 的 GLM 编程 IDE）。
            return ProviderAppMatcher(
                bundleIdentifiers: ["dev.zcode.app"],
                bundleIdentifierFragment: nil,
                processNames: ["zcode"])
        }
    }
}

/// 供测试注入的运行中应用快照，避免测试依赖 NSRunningApplication。
struct RunningAppSnapshot: Equatable {
    let bundleIdentifier: String?
    let processName: String?
}

/// 侦测各供应商桌面应用是否在运行。只读 NSWorkspace，不参与配额刷新；
/// 应用启动 / 退出通知到达时刷新 `runningProviders`。
@MainActor
@Observable
final class ProviderAppPresenceMonitor {
    private(set) var runningProviders: Set<UsageProvider> = []

    private let runningAppSnapshots: () -> [RunningAppSnapshot]
    private var observerTokens: [NSObjectProtocol] = []
    private var hasStarted = false

    init(
        runningAppSnapshots: @escaping () -> [RunningAppSnapshot] =
            ProviderAppPresenceMonitor.liveRunningApps
    ) {
        self.runningAppSnapshots = runningAppSnapshots
        refresh()
    }

    nonisolated static var liveRunningApps: () -> [RunningAppSnapshot] {
        {
            NSWorkspace.shared.runningApplications.map {
                RunningAppSnapshot(
                    bundleIdentifier: $0.bundleIdentifier,
                    processName: $0.localizedName
                        ?? $0.executableURL?.lastPathComponent)
            }
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        for name in names {
            observerTokens.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
    }

    func stop() {
        let tokens = observerTokens
        observerTokens = []
        hasStarted = false
        for token in tokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    func isRunning(_ provider: UsageProvider) -> Bool {
        runningProviders.contains(provider)
    }

    func refresh() {
        let apps = runningAppSnapshots()
        let running = Set(UsageProvider.allCases.filter { provider in
            apps.contains { app in
                provider.companionAppMatcher.matches(
                    bundleIdentifier: app.bundleIdentifier,
                    processName: app.processName)
            }
        })
        // 集合不变时不赋值，避免无谓的 @Observable 变更广播。
        if running != runningProviders {
            runningProviders = running
        }
    }
}
