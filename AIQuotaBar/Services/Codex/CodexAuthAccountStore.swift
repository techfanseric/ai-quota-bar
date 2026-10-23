import AppKit
import CodexLocalUsageCore
import Darwin
import Dispatch
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

/// 一次由外部工具造成的账号变动。
///
/// magpie 这类 LLM 网关会在额度见底时把 Codex 的登录切到别的账号，
/// 并在刷新 token 后回写 auth.json。这些改动都不是本应用发起的，
/// 面板上必须把它说出来，而不是让「当前账号」凭空变一个。
struct CodexExternalAccountChange: Equatable {
    /// 换上去的账号指纹。
    let digest: String
    /// 换上去的账号邮箱（认不出时为 nil）。
    let email: String?
    /// 被换走的账号邮箱（认不出时为 nil）。
    let previousEmail: String?
    let detectedAt: Date
}

/// 守卫命中了哪些对象（桌面版、CLI），决定横幅提示文案。
struct CodexAccountSwitchBlockers: OptionSet, Equatable {
    let rawValue: Int

    static let desktopApp = CodexAccountSwitchBlockers(rawValue: 1 << 0)
    static let cliProcess = CodexAccountSwitchBlockers(rawValue: 1 << 1)
}

/// 切换时 ChatGPT/Codex 桌面版的退出方式。手动（默认）由用户自己在菜单里
/// Quit；自动由应用代替用户执行「激活到前台 + 正常退出」（等同 ⌘Q 的
/// 正常终止路径，不产生异常退出记录）。codex CLI 两种模式下都需手动退出。
enum CodexAccountSwitchExitMode: String, CaseIterable, Codable {
    case manual
    case automatic
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
    /// 面板与设置面板共用的实例。
    static let shared = CodexAuthAccountStore()

    private(set) var currentStatus: CodexAuthFileStatus = .unreadable
    private(set) var currentQuotaSnapshot: CodexAccountQuotaSnapshot?
    private(set) var stashedAccounts: [CodexStashedAccount] = []
    /// ~/.codex 根目录下用户手动改名备份的 `auth *.json` 旧文件。
    private(set) var legacyBackupFileNames: [String] = []
    private(set) var pendingRequest: CodexAccountSwitchRequest?
    private(set) var pendingBlockers: CodexAccountSwitchBlockers = []
    private(set) var statusMessage: CodexAccountSwitchStatusMessage?
    /// 最近一次由外部工具造成的账号变动（本应用自己切的不会记在这里）。
    private(set) var lastExternalAccountChange: CodexExternalAccountChange?

    private let fileManager: FileManager
    private let codexHome: URL
    private let defaults: UserDefaults
    /// 凭据守护镜像：把 auth.json 与账号池里的每份凭据各留一份在 ~/.codex 之外。
    private let authMirror: CodexAuthMirror
    /// 「登录新账号」流程进行中：下一个出现的陌生账号是预期的，不算外部改动。
    private var expectingAnyAccount = false
    /// ~/.codex 目录监听：捕捉 rename / 原子替换。
    private var dirWatcher: DispatchSourceFileSystemObject?
    /// auth.json 文件监听：捕捉原地写入。
    private var fileWatcher: DispatchSourceFileSystemObject?
    /// 兜底轮询：事件是快路径，轮询是保底。
    private var fallbackTimer: Timer?
    /// 目录事件的合并任务：一次改写往往带来多条事件，合并成一次同步。
    private var mirrorSyncTask: Task<Void, Never>?
    private let companionAppsProvider: () -> [RunningAppSnapshot]
    private let cliProcessChecker: () -> Bool
    private let notify: (_ title: String, _ body: String) -> Void
    private let openCompanionApp: () -> Void
    private let quotaSnapshotProvider: @MainActor (String) -> CodexAccountQuotaSnapshot?
    /// 切换/重新登录写完 auth.json 后立即让本机用量模型跟上，
    /// 左键菜单的当前账号不必等 60s 定时刷新才翻转。
    private let usageAccountRefresher: @MainActor () -> Void
    private let autoQuitPerformer: () -> Bool
    private let relaunchDelayProvider: () -> TimeInterval?

    /// 切换时的桌面版退出方式；横幅与设置面板都会改它。
    var exitMode: CodexAccountSwitchExitMode {
        didSet {
            defaults.set(exitMode.rawValue, forKey: Self.exitModeStorageKey)
        }
    }

    static let exitModeStorageKey = "codexAccountSwitchExitMode"
    /// 本轮挂起请求是否已执行过自动退出（避免反复 terminate）。
    private var hasAttemptedAutoQuit = false

    private var pendingObserverTokens: [NSObjectProtocol] = []
    private var pendingTimer: Timer?
    private var displayTimer: Timer?

    init(
        codexHome: URL = CodexAuthAccountStore.defaultCodexHome(),
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        authMirror: CodexAuthMirror = .shared,
        companionAppsProvider: @escaping () -> [RunningAppSnapshot] =
            CodexAuthAccountStore.liveCompanionApps,
        cliProcessChecker: @escaping () -> Bool =
            CodexAuthAccountStore.liveCLIProcessesRunning,
        notify: @escaping (_ title: String, _ body: String) -> Void =
            CodexAuthAccountStore.liveNotify,
        openCompanionApp: @escaping () -> Void =
            CodexAuthAccountStore.liveOpenCompanionApp,
        quotaSnapshotProvider: @escaping @MainActor (String) -> CodexAccountQuotaSnapshot? =
            { CodexAccountQuotaStore.shared.snapshot(for: $0) },
        usageAccountRefresher: @escaping @MainActor () -> Void =
            { CodexLocalUsageModel.shared.refreshCurrentAccount() },
        autoQuitPerformer: @escaping () -> Bool =
            CodexAuthAccountStore.liveAutoQuitDesktopApp,
        relaunchDelayProvider: @escaping () -> TimeInterval? =
            CodexAuthAccountStore.randomRelaunchDelay
    ) {
        self.codexHome = codexHome
        self.fileManager = fileManager
        self.defaults = defaults
        self.authMirror = authMirror
        self.companionAppsProvider = companionAppsProvider
        self.cliProcessChecker = cliProcessChecker
        self.notify = notify
        self.openCompanionApp = openCompanionApp
        self.quotaSnapshotProvider = quotaSnapshotProvider
        self.usageAccountRefresher = usageAccountRefresher
        self.autoQuitPerformer = autoQuitPerformer
        self.relaunchDelayProvider = relaunchDelayProvider
        self.exitMode = defaults.string(forKey: Self.exitModeStorageKey)
            .flatMap(CodexAccountSwitchExitMode.init(rawValue:)) ?? .manual
    }

    deinit {
        // 应用生命周期内由 StatusBarController 持有；接力监控随对象释放，
        // 定时器失效动作不在 deinit 中执行（非隔离上下文不可触碰隔离属性）。
    }

    // MARK: - 路径

    var authURL: URL { codexHome.appendingPathComponent("auth.json") }

    /// 测试用：拿到 auth.json 的真实路径，好让测试制造一次外部改写。
    var authURLForTesting: URL { authURL }

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
        syncAuthMirror()
        if pendingRequest != nil {
            evaluatePendingRequest()
        }
    }

    /// 同步守护镜像，并区分「自己切的」与「外部工具切的」。
    ///
    /// 镜像同步在刷新和目录事件两条路径上都做：展示期 5 秒一次，
    /// 后台 60 秒一次，而目录事件是即时的——外部工具换走 auth.json 的那一刻，
    /// 那个账号的凭据就已经留在镜像里了。
    private func syncAuthMirror() {
        let result = authMirror.sync(
            authURL: authURL, accountsDirectory: accountsDirectory)
        guard case let .accountChanged(digest, previousEmail) = result else { return }

        // 「登录新账号」是用户自己发起的，不算外部改动。
        if expectingAnyAccount {
            expectingAnyAccount = false
            return
        }

        let email = authMirror.email(for: digest)
        lastExternalAccountChange = CodexExternalAccountChange(
            digest: digest, email: email, previousEmail: previousEmail, detectedAt: Date())
        setStatus(
            AppLanguage.current.codexAccountsStatusExternalSwitch(
                from: previousEmail, to: email),
            isError: false)
    }

    // MARK: - 目录监听

    /// 开始监听 ~/.codex 目录与 auth.json 文件本身。
    ///
    /// 两个都要盯，因为两种改写方式产生的事件完全不同（实测）：
    ///
    /// | 改写方式 | 目录事件 | 文件事件 |
    /// | --- | --- | --- |
    /// | 原地写入（打开文件覆盖内容） | **0** | 有 |
    /// | 原子替换（写临时文件后 rename） | 有 | 有（但那是旧 inode 的删除事件） |
    /// | 原子替换后再原地写 | 无 | **收不到**（fd 指向已删除的 inode） |
    ///
    /// 只盯目录会漏掉原地写；只盯文件会在原子替换后失明。
    /// magpie 两种写法都可能用，所以目录与文件都监听，
    /// 目录事件一来就重新挂文件监听，再加一条后台兜底轮询。
    ///
    /// 装上监听之后**立刻同步一次**：目录事件只在有变化时才来，
    /// 不先建立基线的话，app 启动后遇到第一次外部改写时，
    /// 那个账号同样来不及进镜像。
    func startAuthWatching() {
        guard dirWatcher == nil else { return }
        let descriptor = open(codexHome.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // auth.json 可能已经被换成新 inode，文件级监听要重新挂。
                self.rewatchAuthFile()
                self.scheduleMirrorSync()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        dirWatcher = source
        rewatchAuthFile()
        // 建立基线：当前登录的账号先留一份在 ~/.codex 之外。
        syncAuthMirror()
        startFallbackPolling()
    }

    /// 盯住 auth.json 文件本身，捕捉原地写入。
    private func rewatchAuthFile() {
        fileWatcher?.cancel()
        fileWatcher = nil
        let descriptor = open(authURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleMirrorSync() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        fileWatcher = source
    }

    /// 兜底轮询。事件机制是快路径，这里是保底——机制再全也有漏的时候，
    /// 而漏一次就可能意味着一个账号的凭据没能留底。
    private func startFallbackPolling() {
        guard fallbackTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncAuthMirror() }
        }
        timer.tolerance = 2
        fallbackTimer = timer
    }

    /// 停止监听并收掉文件描述符。
    func stopAuthWatching() {
        mirrorSyncTask?.cancel()
        mirrorSyncTask = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        fileWatcher?.cancel()
        fileWatcher = nil
        dirWatcher?.cancel()
        dirWatcher = nil
    }

    /// 一次改写往往带来多条目录事件，合并成一次同步。
    private func scheduleMirrorSync() {
        mirrorSyncTask?.cancel()
        mirrorSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.syncAuthMirror()
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
        hasAttemptedAutoQuit = false
        stopPendingMonitoring()
        setStatus(AppLanguage.current.codexAccountsStatusPendingCancelled(), isError: false)
    }

    /// 切换前的守卫：ChatGPT/Codex 桌面版或 codex CLI 任一在运行就不执行，
    /// 只挂起等待；用户自行退出（或自动模式代为退出）后自动接力。
    /// 已有挂起请求时，最新一次选择覆盖旧意图。
    private func beginOrPerform(_ request: CodexAccountSwitchRequest) {
        if pendingRequest != nil {
            pendingRequest = request
            hasAttemptedAutoQuit = false
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
            evaluatePendingRequest()
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
        var blockers = currentBlockers()
        // 自动模式：应用代替用户退出桌面版（激活 + 正常终止，等同 ⌘Q）。
        // 只在首次评估时执行一次；codex CLI 始终需要用户手动退出。
        if exitMode == .automatic,
           blockers.contains(.desktopApp),
           !hasAttemptedAutoQuit {
            hasAttemptedAutoQuit = true
            _ = autoQuitPerformer()
            blockers = currentBlockers()
        }
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
        hasAttemptedAutoQuit = false
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
            usageAccountRefresher()
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
        guard case let .chatgptLogin(target) = CodexAuthFileReader.read(at: stashURL) else {
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
        // 这次变动是本应用发起的，下一次同步不要把它当成外部工具切号。
        authMirror.acknowledgeLocalChange(digest: target.accountDigest, email: target.email)
        // 用户没有去登录新账号，而是切回了池里的账号——「期待新账号」作废。
        expectingAnyAccount = false

        let display = stashedAccounts.first { $0.label == label }?.email ?? label
        notify(
            language.codexAccountsSwitchNotificationTitle(),
            language.codexAccountsSwitchNotificationBody(display))
        scheduleRelaunch()
    }

    private func performLoginNewAccount() throws {
        let language = AppLanguage.current
        var previousLabel: String?
        if case .chatgptLogin = CodexAuthFileReader.read(at: authURL) {
            previousLabel = try stashCurrentAuth()
        }
        // 接下来出现的是一个全新账号（用户去登录的），不算外部工具切号。
        expectingAnyAccount = true
        notify(
            language.codexAccountsLoginNewNotificationTitle(),
            language.codexAccountsLoginNewNotificationBody(previousLabel: previousLabel))
        scheduleRelaunch()
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

    /// 检测到完全退出后不立即重启：随机延迟 1–2 秒再打开 ChatGPT，
    /// 让退出-重启节奏尽量拟人。
    nonisolated static func randomRelaunchDelay() -> TimeInterval {
        Double.random(in: 1...2)
    }

    private func scheduleRelaunch() {
        guard let delay = relaunchDelayProvider() else {
            openCompanionApp()
            return
        }
        Task { [openCompanionApp] in
            try? await Task.sleep(for: .seconds(delay))
            openCompanionApp()
        }
    }

    /// 自动模式的退出执行：把 ChatGPT/Codex 激活到前台后请求正常终止。
    /// terminate() 走应用自己的正常退出路径（与菜单 Quit / ⌘Q 一致），
    /// 不产生强制结束类异常记录；若应用弹出保存确认等对话框则不再重试，
    /// 交给用户处理。
    nonisolated static func liveAutoQuitDesktopApp() -> Bool {
        let matcher = UsageProvider.codex.companionAppMatcher
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.activationPolicy == .regular && matcher.matches($0)
        }) else { return false }
        app.activate(options: [])
        app.terminate()
        return true
    }

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
