import AppKit
import CodexLocalUsageCore
import Foundation
import Observation
import UserNotifications

/// 账号池（~/.codex/accounts/）里的一份账号备份。
struct CodexStashedAccount: Identifiable, Equatable {
    /// 显示名 = 文件名去掉 .json。
    let label: String
    let status: CodexAuthFileStatus
    let modifiedAt: Date?
    /// 该账号最近一次成功抓取的配额（该账号当时在用期间记录的历史值）。
    let quota: CodexAccountQuotaSnapshot?

    var id: String { label }
    var email: String? {
        if case let .chatgptLogin(login) = status { return login.email }
        return nil
    }

    var accountDigest: String? {
        if case let .chatgptLogin(login) = status { return login.accountDigest }
        return nil
    }

    var isLoggedIn: Bool { status.isLoggedIn }
}

/// 待执行的切换请求。桌面版 / codex CLI 还在运行时挂起，等用户自行
/// 退出后自动接力执行；期间可取消。
enum CodexAccountSwitchRequest: Equatable {
    case switchTo(label: String)
    case loginNewAccount
}

/// 守卫命中了哪些对象（桌面版、CLI），决定横幅提示文案。
struct CodexAccountSwitchBlockers: OptionSet, Equatable {
    let rawValue: Int

    static let desktopApp = CodexAccountSwitchBlockers(rawValue: 1 << 0)
    static let cliProcess = CodexAccountSwitchBlockers(rawValue: 1 << 1)
}

/// 切换完成后面板底部的一行反馈。
struct CodexAccountSwitchStatusMessage: Equatable {
    let text: String
    let isError: Bool
}

/// Codex 免登录切换账号：通过原子改名在 auth.json 与 ~/.codex/accounts/
/// 之间搬运已登录凭据。绝不代替用户退出 ChatGPT / codex CLI，只在两者
/// 都停止后执行切换；文件内容只读取账号指纹与邮箱，不碰 token。
@MainActor
@Observable
final class CodexAuthAccountStore {
    private(set) var currentStatus: CodexAuthFileStatus = .unreadable
    private(set) var currentQuotaSnapshot: CodexAccountQuotaSnapshot?
    private(set) var stashedAccounts: [CodexStashedAccount] = []
    /// ~/.codex 根目录下用户手动改名备份的 `auth *.json` 旧文件。
    private(set) var legacyBackupFileNames: [String] = []
    private(set) var pendingRequest: CodexAccountSwitchRequest?
    private(set) var pendingBlockers: CodexAccountSwitchBlockers = []
    private(set) var statusMessage: CodexAccountSwitchStatusMessage?

    private let fileManager: FileManager
    private let codexHome: URL
    private let companionAppsProvider: () -> [RunningAppSnapshot]
    private let cliProcessChecker: () -> Bool
    private let notify: (_ title: String, _ body: String) -> Void
    private let openCompanionApp: () -> Void
    private let quotaSnapshotProvider: @MainActor (String) -> CodexAccountQuotaSnapshot?

    private var pendingObserverTokens: [NSObjectProtocol] = []
    private var pendingTimer: Timer?
    private var displayTimer: Timer?

    init(
        codexHome: URL = CodexAuthAccountStore.defaultCodexHome(),
        fileManager: FileManager = .default,
        companionAppsProvider: @escaping () -> [RunningAppSnapshot] =
            CodexAuthAccountStore.liveCompanionApps,
        cliProcessChecker: @escaping () -> Bool =
            CodexAuthAccountStore.liveCLIProcessesRunning,
        notify: @escaping (_ title: String, _ body: String) -> Void =
            CodexAuthAccountStore.liveNotify,
        openCompanionApp: @escaping () -> Void =
            CodexAuthAccountStore.liveOpenCompanionApp,
        quotaSnapshotProvider: @escaping @MainActor (String) -> CodexAccountQuotaSnapshot? =
            { CodexAccountQuotaStore.shared.snapshot(for: $0) }
    ) {
        self.codexHome = codexHome
        self.fileManager = fileManager
        self.companionAppsProvider = companionAppsProvider
        self.cliProcessChecker = cliProcessChecker
        self.notify = notify
        self.openCompanionApp = openCompanionApp
        self.quotaSnapshotProvider = quotaSnapshotProvider
    }

    deinit {
        // 应用生命周期内由 StatusBarController 持有；接力监控随对象释放，
        // 定时器失效动作不在 deinit 中执行（非隔离上下文不可触碰隔离属性）。
    }

    // MARK: - 路径

    var authURL: URL { codexHome.appendingPathComponent("auth.json") }
    var accountsDirectory: URL {
        codexHome.appendingPathComponent("accounts", isDirectory: true)
    }

    nonisolated static func defaultCodexHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let configuredHome = environment["CODEX_HOME"], !configuredHome.isEmpty {
            return URL(fileURLWithPath: configuredHome, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }

    // MARK: - 扫描

    func refresh() {
        currentStatus = CodexAuthFileReader.read(at: authURL)
        if case let .chatgptLogin(current) = currentStatus {
            currentQuotaSnapshot = quotaSnapshotProvider(current.accountDigest)
        } else {
            currentQuotaSnapshot = nil
        }
        stashedAccounts = readStashedAccounts()
        legacyBackupFileNames = readLegacyBackupFileNames()
        if pendingRequest != nil {
            evaluatePendingRequest()
        }
    }

    private func readStashedAccounts() -> [CodexStashedAccount] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: accountsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []) else { return [] }
        return entries
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .map { url -> CodexStashedAccount in
                let modified = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]).contentModificationDate
                let status = CodexAuthFileReader.read(at: url)
                let quota: CodexAccountQuotaSnapshot?
                if case let .chatgptLogin(login) = status {
                    quota = quotaSnapshotProvider(login.accountDigest)
                } else {
                    quota = nil
                }
                return CodexStashedAccount(
                    label: url.deletingPathExtension().lastPathComponent,
                    status: status,
                    modifiedAt: modified,
                    quota: quota)
            }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// 用户以前手动改名备份的 auth 文件（如「auth yzx.json」）。
    private func readLegacyBackupFileNames() -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: codexHome,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []) else { return [] }
        return entries
            .filter { url in
                guard let isDirectory = try? url.resourceValues(forKeys: [.isDirectoryKey])
                    .isDirectory, !isDirectory else { return false }
                let name = url.lastPathComponent
                return name.hasPrefix("auth ") && name.hasSuffix(".json")
                    && name.count > "auth .json".count
            }
            .map(\.lastPathComponent)
            .sorted()
    }

    // MARK: - 请求入口（UI 调用）

    func requestSwitch(to label: String) {
        clearStatus()
        guard let stash = stashedAccounts.first(where: { $0.label == label }) else {
            setStatus(AppLanguage.current.codexAccountsStatusTargetMissing(label), isError: true)
            return
        }
        guard stash.isLoggedIn, let digest = stash.accountDigest else {
            setStatus(AppLanguage.current.codexAccountsStatusImportNotLoggedIn(), isError: true)
            return
        }
        if case let .chatgptLogin(current) = currentStatus, current.accountDigest == digest {
            let display = stash.email ?? label
            setStatus(AppLanguage.current.codexAccountsStatusAlreadyCurrent(display), isError: false)
            return
        }
        beginOrPerform(.switchTo(label: label))
    }

    func requestLoginNewAccount() {
        clearStatus()
        beginOrPerform(.loginNewAccount)
    }

    func cancelPendingRequest() {
        guard pendingRequest != nil else { return }
        pendingRequest = nil
        pendingBlockers = []
        stopPendingMonitoring()
        setStatus(AppLanguage.current.codexAccountsStatusPendingCancelled(), isError: false)
    }

    /// 切换前的守卫：ChatGPT/Codex 桌面版或 codex CLI 任一在运行就不执行，
    /// 只挂起等待；用户自行退出后自动接力。已有挂起请求时，最新一次选择
    /// 覆盖旧意图。
    private func beginOrPerform(_ request: CodexAccountSwitchRequest) {
        if pendingRequest != nil {
            pendingRequest = request
            let blockers = currentBlockers()
            pendingBlockers = blockers
            if blockers.isEmpty {
                evaluatePendingRequest()
            }
            return
        }
        refresh()
        let blockers = currentBlockers()
        guard blockers.isEmpty else {
            pendingRequest = request
            pendingBlockers = blockers
            startPendingMonitoring()
            return
        }
        perform(request)
    }

    private func currentBlockers() -> CodexAccountSwitchBlockers {
        var blockers: CodexAccountSwitchBlockers = []
        let matcher = UsageProvider.codex.companionAppMatcher
        if companionAppsProvider().contains(where: {
            matcher.matches(
                bundleIdentifier: $0.bundleIdentifier,
                processName: $0.processName)
        }) {
            blockers.insert(.desktopApp)
        }
        if cliProcessChecker() {
            blockers.insert(.cliProcess)
        }
        return blockers
    }

    /// 定时器 / 工作区通知 / 测试共同调用的接力检查点。
    func evaluatePendingRequest() {
        guard let request = pendingRequest else { return }
        let blockers = currentBlockers()
        guard blockers.isEmpty else {
            pendingBlockers = blockers
            return
        }
        perform(request)
    }

    /// 执行前最后一刻再查一次运行状态，避免决定执行与改名之间的竞态。
    private func perform(_ request: CodexAccountSwitchRequest) {
        let blockers = currentBlockers()
        guard blockers.isEmpty else {
            pendingRequest = request
            pendingBlockers = blockers
            startPendingMonitoring()
            return
        }
        pendingRequest = nil
        pendingBlockers = []
        stopPendingMonitoring()
        let language = AppLanguage.current
        do {
            switch request {
            case let .switchTo(label):
                try performSwitch(to: label)
                setStatus(language.codexAccountsStatusSwitched(label), isError: false)
            case .loginNewAccount:
                try performLoginNewAccount()
            }
        } catch {
            if let message = error as? CodexAccountSwitchError {
                setStatus(message.text, isError: true)
            } else {
                setStatus(
                    language.codexAccountsStatusOperationFailed(error.localizedDescription),
                    isError: true)
            }
        }
        refresh()
    }

    // MARK: - 改名执行

    private func performSwitch(to label: String) throws {
        let language = AppLanguage.current
        let stashURL = accountsDirectory.appendingPathComponent(label + ".json")
        guard fileManager.fileExists(atPath: stashURL.path) else {
            throw CodexAccountSwitchError(
                text: language.codexAccountsStatusTargetMissing(label))
        }
        // 目标备份必须仍是已登录凭据才允许上位。
        guard case .chatgptLogin = CodexAuthFileReader.read(at: stashURL) else {
            throw CodexAccountSwitchError(
                text: language.codexAccountsStatusImportNotLoggedIn())
        }
        // 1. 当前登录中的账号先改名入池（同账号已有备份时用较新的这份替换）。
        let currentRead = CodexAuthFileReader.read(at: authURL)
        if case .chatgptLogin = currentRead {
            _ = try stashCurrentAuth()
        } else if fileManager.fileExists(atPath: authURL.path) {
            // 未登录的占位 auth 由 Codex 重新生成，可以直接移除；
            // API Key 模式或无法识别的文件不能动，交还给用户处理。
            guard currentRead == .unauthenticated else {
                throw CodexAccountSwitchError(
                    text: language.codexAccountsStatusOperationFailed(authURL.path))
            }
            try fileManager.removeItem(at: authURL)
        }
        // 2. 目标备份上位为正式 auth.json。
        try fileManager.moveItem(at: stashURL, to: authURL)

        let display = stashedAccounts.first { $0.label == label }?.email ?? label
        notify(
            language.codexAccountsSwitchNotificationTitle(),
            language.codexAccountsSwitchNotificationBody(display))
        openCompanionApp()
    }

    private func performLoginNewAccount() throws {
        let language = AppLanguage.current
        var previousLabel: String?
        if case .chatgptLogin = CodexAuthFileReader.read(at: authURL) {
            previousLabel = try stashCurrentAuth()
        }
        notify(
            language.codexAccountsLoginNewNotificationTitle(),
            language.codexAccountsLoginNewNotificationBody(previousLabel: previousLabel))
        openCompanionApp()
        if let previousLabel {
            setStatus(language.codexAccountsStatusStashed(previousLabel), isError: false)
        }
    }

    /// 把当前 auth.json 改名存入账号池，返回入池后的显示名。
    /// 同一账号（指纹相同）已存在备份时，用较新的当前文件替换旧备份。
    @discardableResult
    private func stashCurrentAuth() throws -> String {
        let language = AppLanguage.current
        guard case let .chatgptLogin(login) = CodexAuthFileReader.read(at: authURL) else {
            throw CodexAccountSwitchError(
                text: language.codexAccountsStatusImportNotLoggedIn())
        }
        try fileManager.createDirectory(
            at: accountsDirectory, withIntermediateDirectories: true)
        if let existing = readStashedAccounts().first(where: {
            $0.accountDigest == login.accountDigest
        }) {
            let existingURL = accountsDirectory.appendingPathComponent(
                existing.label + ".json")
            try fileManager.removeItem(at: existingURL)
            try fileManager.moveItem(at: authURL, to: existingURL)
            return existing.label
        }
        let label = uniqueLabel(
            base: Self.sanitizedLabel(baseName(for: login.email)) ?? "account")
        try fileManager.moveItem(
            at: authURL,
            to: accountsDirectory.appendingPathComponent(label + ".json"))
        return label
    }

    // MARK: - 备份管理

    func renameStashedAccount(_ label: String, to newLabel: String) {
        clearStatus()
        let sanitized = Self.sanitizedLabel(newLabel)
        guard let sanitized, !sanitized.isEmpty else { return }
        do {
            let source = accountsDirectory.appendingPathComponent(label + ".json")
            guard fileManager.fileExists(atPath: source.path) else {
                throw CodexAccountSwitchError(
                    text: AppLanguage.current.codexAccountsStatusTargetMissing(label))
            }
            let destination = uniqueLabel(
                base: sanitized, excluding: label)
            try fileManager.moveItem(
                at: source,
                to: accountsDirectory.appendingPathComponent(destination + ".json"))
            refresh()
            setStatus(AppLanguage.current.codexAccountsStatusRenamed(), isError: false)
        } catch {
            setStatus(
                AppLanguage.current.codexAccountsStatusOperationFailed(
                    error.localizedDescription),
                isError: true)
        }
    }

    func deleteStashedAccount(_ label: String) {
        clearStatus()
        let url = accountsDirectory.appendingPathComponent(label + ".json")
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            // 优先移入废纸篓，可恢复；失败（如自卷）再直接删除。
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        } catch {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                setStatus(
                    AppLanguage.current.codexAccountsStatusOperationFailed(
                        error.localizedDescription),
                    isError: true)
                return
            }
        }
        refresh()
        setStatus(AppLanguage.current.codexAccountsStatusDeleted(label), isError: false)
    }

    /// 把根目录的手动备份（auth yzx.json 等）收编进账号池。
    func importLegacyBackup(_ fileName: String) {
        clearStatus()
        let language = AppLanguage.current
        let source = codexHome.appendingPathComponent(fileName)
        guard case let .chatgptLogin(login) = CodexAuthFileReader.read(at: source) else {
            setStatus(language.codexAccountsStatusImportNotLoggedIn(), isError: true)
            return
        }
        do {
            try fileManager.createDirectory(
                at: accountsDirectory, withIntermediateDirectories: true)
            if let existing = readStashedAccounts().first(where: {
                $0.accountDigest == login.accountDigest
            }) {
                setStatus(
                    language.codexAccountsStatusImportAlreadyInPool(
                        existing.email ?? existing.label),
                    isError: false)
                return
            }
            let label = uniqueLabel(
                base: Self.sanitizedLabel(baseName(for: login.email)) ?? "account")
            try fileManager.moveItem(
                at: source,
                to: accountsDirectory.appendingPathComponent(label + ".json"))
            refresh()
            setStatus(language.codexAccountsStatusImported(label), isError: false)
        } catch {
            setStatus(
                language.codexAccountsStatusOperationFailed(error.localizedDescription),
                isError: true)
        }
    }

    // MARK: - 接力监控

    private func startPendingMonitoring() {
        guard pendingTimer == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            pendingObserverTokens.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.evaluatePendingRequest() }
            })
        }
        let timer = Timer.scheduledTimer(
            withTimeInterval: 3, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluatePendingRequest() }
        }
        timer.tolerance = 1
        pendingTimer = timer
    }

    private func stopPendingMonitoring() {
        let tokens = pendingObserverTokens
        pendingObserverTokens = []
        for token in tokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        pendingTimer?.invalidate()
        pendingTimer = nil
    }

    // MARK: - 面板展示期轻量轮询

    func beginDisplayRefresh() {
        refresh()
        guard displayTimer == nil else { return }
        let timer = Timer.scheduledTimer(
            withTimeInterval: 5, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer.tolerance = 2
        displayTimer = timer
    }

    func endDisplayRefresh() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    // MARK: - 默认注入实现

    /// 只统计常规 GUI 应用：插件宿主等后台可执行文件（如
    /// ~/.codex/plugins/.../ChatGPT）不算「桌面版在运行」。
    nonisolated static func liveCompanionApps() -> [RunningAppSnapshot] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { application in
                RunningAppSnapshot(
                    bundleIdentifier: application.bundleIdentifier,
                    processName: application.localizedName
                        ?? application.executableURL?.lastPathComponent)
            }
    }

    /// codex CLI 以 node 脚本（@openai/codex/bin/codex.js）或同名二进制运行；
    /// 两种形态都能被 pgrep 命中。
    nonisolated static func liveCLIProcessesRunning() -> Bool {
        for arguments in [["-x", "codex"], ["-f", "@openai/codex"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = arguments
            do {
                try process.run()
            } catch {
                continue
            }
            process.waitUntilExit()
            if process.terminationStatus == 0 { return true }
        }
        return false
    }

    nonisolated static func liveNotify(title: String, body: String) {
        Task.detached {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            let authorized: Bool
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                authorized = true
            case .notDetermined:
                authorized = (try? await center.requestAuthorization(
                    options: [.alert, .sound])) ?? false
            case .denied:
                authorized = false
            @unknown default:
                authorized = false
            }
            guard authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "codex-account-switch-\(UUID().uuidString)",
                content: content,
                trigger: nil)
            _ = try? await center.add(request)
        }
    }

    nonisolated static func liveOpenCompanionApp() {
        let identifiers = [
            "com.openai.chat",
            "com.openai.codex",
            "com.openai.chatgpt.codex",
        ]
        for identifier in identifiers {
            if let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: identifier) {
                NSWorkspace.shared.openApplication(
                    at: url, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
    }

    // MARK: - 命名工具

    private func baseName(for email: String?) -> String {
        guard let email, !email.isEmpty else { return "account" }
        return String(email.split(separator: "@").first ?? "account")
    }

    /// 文件名只保留可读字符，禁止路径分隔符；空结果返回 nil。
    static func sanitizedLabel(_ raw: String) -> String? {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = raw.components(separatedBy: forbidden)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != "." , cleaned != ".." else { return nil }
        return String(cleaned.prefix(60))
    }

    /// 冲突时追加「 2」「 3」…；excluding 用于重命名时跳过自身旧名。
    private func uniqueLabel(base: String, excluding: String? = nil) -> String {
        let existingLabels = Set(readStashedAccounts().map(\.label))
        var candidate = base
        var suffix = 2
        while candidate != excluding, existingLabels.contains(candidate) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func setStatus(_ text: String, isError: Bool) {
        statusMessage = CodexAccountSwitchStatusMessage(text: text, isError: isError)
    }

    private func clearStatus() {
        statusMessage = nil
    }
}

/// 携带已本地化文案的业务错误，perform 统一展示到面板状态行。
struct CodexAccountSwitchError: Error {
    let text: String
}
