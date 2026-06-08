import Foundation
import AppKit

/// Main view model managing usage state and refresh logic
@MainActor
@Observable
final class UsageViewModel {
    // MARK: - Published State

    var usageData: UsageData? {
        didSet { checkThreshold() }
    }
    var providerUsageData: [UsageProvider: UsageData] = [:]
    var cloudProviderUsageData: [UsageProvider: UsageData] = [:]
    var cloudUsageLoadError: String?
    var providerErrors: [UsageProvider: UsageError] = [:]
    var error: UsageError?
    var isLoading: Bool = false
    var lastRefreshTime: Date?
    var showWarningPanel: Bool = false
    private(set) var modelQuotaSamples: [String: [ModelQuotaSample]] = [:]
    private var utilizationHistories: [UsageProvider: ModelUtilizationStoreData] = [:]
    private let utilizationStore = ModelUtilizationHistoryStore.shared
    private let utilizationSampleThrottle: TimeInterval = 3600

    // MARK: - Settings

    var refreshInterval: Int {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
            restartTimer()
        }
    }

    var warningThreshold: Double {
        didSet {
            UserDefaults.standard.set(warningThreshold, forKey: "warningThreshold")
            checkThreshold()
        }
    }

    var warningThresholdEnabled: Bool {
        didSet {
            UserDefaults.standard.set(warningThresholdEnabled, forKey: "warningThresholdEnabled")
        }
    }

    /// 实际生效的阈值：未启用时返回 0，调用方可以放心用 `> 0` 判断
    var effectiveWarningThreshold: Double {
        warningThresholdEnabled ? warningThreshold : 0
    }

    var autoRefreshOnLaunch: Bool {
        didSet {
            UserDefaults.standard.set(autoRefreshOnLaunch, forKey: "autoRefreshOnLaunch")
        }
    }

    var appLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(appLanguage.rawValue, forKey: AppLanguage.storageKey)
            updateStatusBarText()
        }
    }

    var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            AutoLaunchService.shared.setEnabled(launchAtLogin)
        }
    }

    var cloudSyncEnabled: Bool {
        didSet {
            saveCloudSyncSettings()
        }
    }

    var utilizationHistoryMode: UtilizationHistoryMode {
        didSet {
            UserDefaults.standard.set(utilizationHistoryMode.rawValue, forKey: Self.utilizationHistoryModeKey)
        }
    }

    private static let utilizationHistoryModeKey = "utilizationHistoryMode"

    // MARK: - Computed Properties

    var statusBarText: String = "..."

    var availableModels: [ModelUsageData] {
        guard let data = usageData else { return [] }
        return menuBarCandidateModels(from: data.models, now: Date())
    }

    private func updateStatusBarText() {
        guard let data = usageData else {
            if error != nil {
                statusBarText = "—"
            } else {
                // 还没拉到数据(初次启动 / 等待刷新):每个已配置 provider 占一行 "Xxx loading"
                // 顺序跟正常态对齐:codex 优先,再 minimax,再 glm
                let displayOrder: [UsageProvider] = [.codex, .miniMax, .glm]
                let placeholders = displayOrder
                    .filter { configuredProviders.contains($0) }
                    .map { "\($0.displayName) loading" }
                statusBarText = placeholders.isEmpty ? "..." : placeholders.joined(separator: "\n")
            }
            return
        }

        let now = Date()
        let candidates = menuBarCandidateModels(from: data.models, now: now)

        // 状态栏两行：每行一个 provider 的状态
        // codex: primary 用 5h model(显示 5h 剩余% 和 5h reset),
        //         paceDelta 从 Weekly model 算(周限额 reserve)
        let primary: ModelUsageData? = pickPrimary(from: candidates)

        var secondary: ModelUsageData?
        if let primary {
            let remainingCandidates = candidates.filter { $0.provider != primary.provider }
            secondary = pickPrimary(from: remainingCandidates)
        } else {
            secondary = candidates.dropFirst().first
        }

        var lines: [String] = []
        if let primary {
            // codex 时 paceSource 传 weekly model(用周限额算 paceDelta)
            let paceSource: ModelUsageData? = (primary.provider == .codex) ? weeklyModel(in: candidates) : nil
            lines.append(primary.formattedStatusBarLine(
                providerInitial: providerInitial(primary.provider),
                paceSource: paceSource))
        }
        if let secondary {
            let paceSource: ModelUsageData? = (secondary.provider == .codex) ? weeklyModel(in: candidates) : nil
            lines.append(secondary.formattedStatusBarLine(
                providerInitial: providerInitial(secondary.provider),
                paceSource: paceSource))
        }

        statusBarText = lines.isEmpty ? "—" : lines.joined(separator: "\n")
    }

    /// 选 status bar 主显示 model:
    /// - codex 选 "5h" model(显示 5h 短周期剩余%/reset)
    /// - 其他 provider 取 candidates 第一个(已按 reset 排序)
    private func pickPrimary(from candidates: [ModelUsageData]) -> ModelUsageData? {
        if let codex = candidates.first(where: { $0.provider == .codex && $0.modelName.localizedCaseInsensitiveContains("5h") }) {
            return codex
        }
        return candidates.first
    }

    /// 从 candidates 里找 codex 的 "Weekly" model(用来算周限额 paceDelta)
    private func weeklyModel(in candidates: [ModelUsageData]) -> ModelUsageData? {
        candidates.first(where: { $0.provider == .codex && $0.modelName.localizedCaseInsensitiveContains("Weekly") })
    }

    private func providerInitial(_ provider: UsageProvider) -> String {
        switch provider {
        case .miniMax: return "M"
        case .codex: return "C"
        case .glm: return "G"
        }
    }

    var hasAPIKey: Bool {
        hasAnyCredential
    }

    var hasAnyCredential: Bool {
        configuredProviders.isEmpty == false
    }

    var configuredProviders: [UsageProvider] {
        UsageProvider.allCases.filter { isConfigured($0) }
    }

    /// 判断 provider 是否应该被纳入刷新与下拉菜单。
    /// MiniMax / GLM 走 Keychain；Codex 由 codexbar 的 managed account store 自管，
    /// 凭证在 `~/.codex`（CLI）或 `~/.codexbar`（managed store）。
    /// 这里始终让 Codex 算 configured：fetch 时 codexbar 自己会返回 unauthorized 之类的错误，
    /// dropdown 不会展示该 section，Settings 仍能进 Codex 段做添加/移除操作。
    private func isConfigured(_ provider: UsageProvider) -> Bool {
        switch provider {
        case .codex:
            return true
        default:
            return KeychainService.shared.hasCredential(for: provider)
        }
    }

    var providerUsageSections: [UsageData] {
        guard !isLoading || !providerUsageData.isEmpty else { return [] }
        let localDataByProvider = providerUsageData.mapValues { data in
            data.withModels(accountScopedLocalModels(data.models))
        }
        let remoteCloudModels = cloudProviderUsageData.values
            .flatMap(\.models)
            .filter { !$0.isCloudNoiseModel }
        let remoteCloudModelKeys = Set(remoteCloudModels.map(\.quotaIdentityKey))
        let localModelKeys = Set(localDataByProvider.values.flatMap(\.models).map(\.quotaIdentityKey))
        let historyCloudModels = supplementalCloudModelsFromHistory(excluding: localModelKeys.union(remoteCloudModelKeys))
        let cloudModels = remoteCloudModels + historyCloudModels
        let cloudModelKeys = Set(cloudModels.map(\.quotaIdentityKey))

        return UsageProvider.allCases
            .compactMap { provider -> UsageData? in
                let localModels = (localDataByProvider[provider]?.models ?? []).map { model in
                    cloudModelKeys.contains(model.quotaIdentityKey)
                        ? model.withDetailSource("Mix")
                        : model
                }
                let providerCloudModels = cloudModels.filter { $0.provider == provider }
                let cloudOnlyModels = providerCloudModels.filter { model in
                    !localModelKeys.contains(model.quotaIdentityKey)
                        && !model.isCloudNoiseModel
                }
                let models = localModels + cloudOnlyModels
                guard !models.isEmpty else { return nil }

                let baseData = localDataByProvider[provider]
                    ?? cloudProviderUsageData[provider]
                    ?? UsageData(
                        provider: provider,
                        remains: models.filter(\.isCurrentIntervalAvailable).count,
                        total: models.count,
                        timestamp: Date(),
                        models: models,
                        subscribeTitle: nil,
                        subscribeEndTime: nil)
                return baseData.withModels(models)
            }
    }

    // MARK: - Private

    private var timer: Timer?

    // MARK: - Initialization

    init() {
        self.refreshInterval = UserDefaults.standard.object(forKey: "refreshInterval") as? Int ?? 60
        self.warningThreshold = UserDefaults.standard.double(forKey: "warningThreshold") > 0
            ? UserDefaults.standard.double(forKey: "warningThreshold")
            : 20.0
        self.warningThresholdEnabled = UserDefaults.standard.object(forKey: "warningThresholdEnabled") as? Bool ?? false
        self.autoRefreshOnLaunch = UserDefaults.standard.object(forKey: "autoRefreshOnLaunch") as? Bool ?? true
        self.appLanguage = UserDefaults.standard.string(forKey: AppLanguage.storageKey)
            .flatMap(AppLanguage.init(rawValue:))
            ?? AppLanguage.fallback
        self.launchAtLogin = UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool ?? false
        let cloudSyncSettings = CloudSyncSettings.current
        self.cloudSyncEnabled = cloudSyncSettings.isEnabled
        self.utilizationHistoryMode = UserDefaults.standard.string(forKey: Self.utilizationHistoryModeKey)
            .flatMap(UtilizationHistoryMode.init(rawValue:))
            ?? .includeCurrent

        loadUtilizationHistories()
        updateStatusBarText()
        if cloudSyncEnabled {
            Task { @MainActor in
                await refreshCloudUsageData()
            }
        }
    }

    // MARK: - Public Methods

    func refresh() async {
        guard !isLoading else { return }

        isLoading = true
        error = nil
        providerErrors = [:]

        let allConfiguredProviders = configuredProviders
        let providers = allConfiguredProviders.filter(shouldFetchProvider)
        let skippedProviders = allConfiguredProviders.filter { !shouldFetchProvider($0) }
        guard providers.isEmpty == false else {
            providerErrors = [:]
            usageData = combinedUsageData(from: providerUsageData.values, timestamp: lastRefreshTime ?? Date())
            error = providerUsageData.isEmpty ? .notConfigured : nil
            await refreshCloudUsageData()
            updateStatusBarText()
            isLoading = false
            return
        }

        var nextProviderData: [UsageProvider: UsageData] = [:]
        var fetchedProviderData: [UsageProvider: UsageData] = [:]
        var nextProviderErrors: [UsageProvider: UsageError] = [:]
        let sampleTimestamp = Date()
        for provider in skippedProviders {
            if let previous = providerUsageData[provider] {
                nextProviderData[provider] = previous
            }
        }

        // 并行 fetch：3 个 provider 全开时延迟从 ~30s 降到 ~10s（取最慢的）。
        // recordUtilizationSamples 必须保持 main-actor 同步语义，所以放在 for await 块里。
        await withTaskGroup(of: (UsageProvider, Result<UsageData, Error>).self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        let data = try await UsageService.shared.fetchUsage(provider: provider)
                        return (provider, .success(data))
                    } catch {
                        return (provider, .failure(error))
                    }
                }
            }
            for await (provider, result) in group {
                if Task.isCancelled {
                    // 显式 cancel 兄弟子任务:fetchUsage 内部不调 checkCancellation,
                    // URLSession 也不会自动 abort,只能靠 task 取消让闭包内 await 抛 CancellationError
                    group.cancelAll()
                    break
                }
                switch result {
                case .success(let data):
                    nextProviderData[provider] = data
                    fetchedProviderData[provider] = data
                    recordUtilizationSamples(for: provider, data: data, capturedAt: sampleTimestamp)
                case .failure(let error):
                    if let previous = providerUsageData[provider] {
                        nextProviderData[provider] = previous
                    }
                    if let usError = error as? UsageError {
                        nextProviderErrors[provider] = usError
                    } else {
                        nextProviderErrors[provider] = .networkError(error)
                    }
                }
            }
        }

        providerUsageData = nextProviderData
        providerErrors = nextProviderErrors
        usageData = combinedUsageData(from: nextProviderData.values, timestamp: sampleTimestamp)
        error = usageData == nil ? nextProviderErrors.values.first : nil
        if let usageData {
            lastRefreshTime = sampleTimestamp
            recordSamples(from: usageData, timestamp: sampleTimestamp)
            if let freshlyFetchedUsageData = combinedUsageData(from: fetchedProviderData.values, timestamp: sampleTimestamp) {
                syncUsageDataToCloud(freshlyFetchedUsageData, sampledAt: sampleTimestamp)
            }
        }
        await refreshCloudUsageData()
        updateStatusBarText()
        checkThreshold()

        isLoading = false
    }

    private func shouldFetchProvider(_ provider: UsageProvider) -> Bool {
        switch provider {
        case .codex:
            return CodexAppPresence.isRunning
        case .miniMax, .glm:
            return true
        }
    }

    func startAutoRefresh() {
        guard hasAnyCredential else { return }
        restartTimer()

        if autoRefreshOnLaunch || usageData == nil {
            Task {
                await refresh()
            }
        }
    }

    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
    }

    func saveAPIKey(_ key: String) -> Bool {
        saveCredential(key, for: .miniMax)
    }

    func saveCredential(_ credential: String, for provider: UsageProvider) -> Bool {
        let preparedCredential: String
        do {
            preparedCredential = try UsageService.shared.prepareCredentialForStorage(credential, provider: provider)
        } catch let usError as UsageError {
            error = usError
            return false
        } catch {
            self.error = .invalidResponse
            return false
        }

        let success = KeychainService.shared.saveCredential(preparedCredential, for: provider)
        if success {
            error = nil
            Task {
                await refresh()
            }
        }
        return success
    }

    func testAPIKey(_ key: String) async throws -> Bool {
        return try await UsageService.shared.testConnection(credential: key, provider: .miniMax)
    }

    func testCredential(_ credential: String, provider: UsageProvider) async throws -> Bool {
        return try await UsageService.shared.testConnection(credential: credential, provider: provider)
    }

    func effectiveCloudSyncEndpointURL() -> String {
        CloudSyncSettings.defaultEndpointURLString
    }

    func effectiveCloudSyncToken() -> String {
        CloudSyncSettings.defaultServiceToken
    }

    func dataReportSnapshot() -> DataReportSnapshot {
        DataReportSnapshot(
            generatedAt: Date(),
            usageData: usageData,
            providerUsageData: providerUsageData,
            modelQuotaSamples: modelQuotaSamples,
            utilizationHistories: utilizationHistories
        )
    }

    func clearCloudUsageData() {
        cloudProviderUsageData = [:]
    }

    func clearLocalUsageData() {
        usageData = nil
        providerUsageData = [:]
        providerErrors = [:]
        error = nil
        lastRefreshTime = nil
        modelQuotaSamples = [:]
        utilizationHistories = [:]
        utilizationStore.clearAll()
        CloudSyncService.shared.clearPendingQueue()
        updateStatusBarText()
    }

    /// 云端同步状态：proxy 自 `CloudSyncService.shared.lastSyncStatus`。
    /// 设置面板的 `CloudSyncStatusLine` 实时显示"上次同步 Xm ago" / "失败 Ym ago"。
    var cloudSyncStatus: CloudSyncStatus {
        CloudSyncService.shared.lastSyncStatus
    }

    func testCloudSync(endpointURL: String, token: String) async throws {
        try await CloudSyncService.shared.testConnection(endpointURLString: endpointURL, token: token)
    }

    func samples(for model: ModelUsageData) -> [ModelQuotaSample] {
        guard model.isShortCurrentInterval,
              let startTime = model.startTime,
              let endTime = model.endTime else {
            return []
        }

#if DEBUG
        return syntheticMinuteSamples(for: model, startTime: startTime, endTime: endTime)
#else
        return (modelQuotaSamples[model.id] ?? [])
            .filter { $0.timestamp >= startTime && $0.timestamp <= endTime }
            .sorted { $0.timestamp < $1.timestamp }
#endif
    }

    /// 跨周期 utilization 柱图数据：按 `resetsAt` 分组取 peak usedPercent，倒序排列。
    /// 模式由 `utilizationHistoryMode` 决定是否包含当前 in-progress 周期。
    /// `limit` 默认 30（约 6 天的 5h 周期），周长周期调用方传 12（约 3 个月）。
    func utilizationCycles(for model: ModelUsageData, limit: Int = 30, now: Date = Date()) -> [(resetsAt: Date, peakPercent: Double)] {
        let histories = utilizationHistories[model.provider]?.historiesOrEmpty ?? [:]
        let history = utilizationHistoryLookupIDs(for: model)
            .lazy
            .compactMap { histories[$0] }
            .first
        return history?.cycles(limit: limit, now: now, mode: utilizationHistoryMode) ?? []
    }

    // MARK: - Private Methods

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(refreshInterval), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    /// init 同步预加载所有 provider 的历史（文件小可接受）。
    private func loadUtilizationHistories() {
        for provider in UsageProvider.allCases {
            utilizationHistories[provider] = utilizationStore.load(for: provider)
        }
    }

    /// 把单次成功刷新的 model 状态写入历史：1h 节流、append-only、整体落盘。
    /// 仅在 `currentIntervalRemainingPercent` 或 `currentIntervalTotal > 0` 时才计算 usedPercent。
    private func recordUtilizationSamples(for provider: UsageProvider, data: UsageData, capturedAt: Date) {
        var store = utilizationHistories[provider] ?? ModelUtilizationStoreData()
        var dirty = false

        for model in data.models {
            guard shouldRecordUtilizationHistory(for: model) else { continue }
            guard let endTime = model.endTime else { continue }

            let usedPercent: Double
            if let percent = model.currentIntervalRemainingPercent {
                usedPercent = max(0, min(100, 100 - Double(percent)))
            } else if model.currentIntervalTotal > 0 {
                usedPercent = max(0, min(100, Double(model.currentIntervalUsedCount) / Double(model.currentIntervalTotal) * 100))
            } else {
                continue
            }

            var history = store.historiesOrEmpty[model.id] ?? ModelUtilizationHistory(modelId: model.id)
            if let last = history.entries.last,
               capturedAt.timeIntervalSince(last.capturedAt) < utilizationSampleThrottle {
                continue
            }
            history.append(UtilizationHistoryEntry(
                capturedAt: capturedAt,
                usedPercent: usedPercent,
                resetsAt: endTime
            ))
            var histories = store.historiesOrEmpty
            histories[model.id] = history
            store.histories = histories
            dirty = true
        }

        if dirty {
            utilizationHistories[provider] = store
            utilizationStore.save(store, for: provider)
        }
    }

    private func utilizationHistoryLookupIDs(for model: ModelUsageData) -> [String] {
        [model.id]
    }

    private func shouldRecordUtilizationHistory(for model: ModelUsageData) -> Bool {
        true
    }

    private func accountScopedLocalModels(_ models: [ModelUsageData]) -> [ModelUsageData] {
        let codexAccountNames = Set(models
            .filter { $0.provider == .codex }
            .compactMap { model -> String? in
                let normalized = model.normalizedAccountName
                guard !normalized.isEmpty else { return nil }
                return model.accountName?.trimmingCharacters(in: .whitespacesAndNewlines)
            })
        guard !codexAccountNames.isEmpty else { return models }

        if codexAccountNames.count == 1, let accountName = codexAccountNames.first {
            return models.map { model in
                if model.provider == .codex, model.normalizedAccountName.isEmpty {
                    return model.withAccountName(accountName)
                }
                return model
            }
        }

        return models.filter { model in
            if model.provider == .codex, model.normalizedAccountName.isEmpty {
                return false
            }
            return true
        }
    }

    private func supplementalCloudModelsFromHistory(excluding existingKeys: Set<String>) -> [ModelUsageData] {
        utilizationHistories.values
            .flatMap(\.historiesOrEmpty)
            .compactMap { _, history in
                supplementalCloudModel(from: history, excluding: existingKeys)
            }
    }

    private func supplementalCloudModel(
        from history: ModelUtilizationHistory,
        excluding existingKeys: Set<String>) -> ModelUsageData?
    {
        guard let parsed = parseHistoryModelID(history.modelId),
              !parsed.accountName.isEmpty,
              let latest = history.entries.sorted(by: { $0.capturedAt > $1.capturedAt }).first else {
            return nil
        }

        let remainingPercent = Int(max(0, min(100, 100 - latest.usedPercent)).rounded())
        let key = [
            parsed.provider.rawValue,
            parsed.accountName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            parsed.modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
        ].joined(separator: ":")
        guard !existingKeys.contains(key) else { return nil }

        let endTime = latest.resetsAt
        let startTime = endTime.flatMap { reset in
            inferredHistoryDuration(for: parsed.modelName).map { reset.addingTimeInterval(-$0) }
        }

        return ModelUsageData(
            provider: parsed.provider,
            accountName: parsed.accountName,
            modelName: parsed.modelName,
            currentIntervalTotal: 100,
            currentIntervalUsed: remainingPercent,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: endTime.map { Int($0.timeIntervalSince(Date()) * 1000) } ?? 0,
            startTime: startTime,
            endTime: endTime,
            weeklyStartTime: nil,
            weeklyEndTime: nil,
            valueSuffix: "%",
            detailText: "Cloud" + historyResetDetail(endTime),
            currentIntervalRemainingPercent: remainingPercent,
            weeklyRemainingPercent: nil,
            progressBarPercentOverride: nil,
            progressBarRightText: nil,
            sampledAt: latest.capturedAt)
    }

    private func parseHistoryModelID(_ id: String) -> (provider: UsageProvider, accountName: String, modelName: String)? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3,
              let provider = UsageProvider(rawValue: parts[0]) else {
            return nil
        }
        let accountName = parts[1]
        let modelName = parts.dropFirst(2).joined(separator: ":")
        guard !accountName.isEmpty, !modelName.isEmpty else { return nil }
        return (provider, accountName, modelName)
    }

    private func inferredHistoryDuration(for modelName: String) -> TimeInterval? {
        let lower = modelName.lowercased()
        if lower.contains("weekly") || lower == "weekly" {
            return 7 * 24 * 3600
        }
        if lower.contains("5h") || lower.contains("5-hour") || lower.contains("5 hour") {
            return 5 * 3600
        }
        return nil
    }

    private func historyResetDetail(_ endTime: Date?) -> String {
        guard let endTime else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM/dd HH:mm"
        return " · resets \(formatter.string(from: endTime))"
    }

    private func saveCloudSyncSettings() {
        CloudSyncSettings(
            isEnabled: cloudSyncEnabled,
            endpointURLString: CloudSyncSettings.defaultEndpointURLString,
            deviceID: CloudSyncSettings.current.deviceID
        ).save()
        if cloudSyncEnabled {
            Task { @MainActor in
                await refreshCloudUsageData()
            }
        } else {
            cloudProviderUsageData = [:]
        }
    }

    private func refreshCloudUsageData() async {
        guard cloudSyncEnabled else {
            cloudProviderUsageData = [:]
            return
        }

        do {
            cloudProviderUsageData = try await CloudSyncService.shared.fetchRemoteUsageData()
            cloudUsageLoadError = nil
        } catch {
            // Cloud rows are supplemental. Keep local quota usable if remote history cannot load.
            cloudProviderUsageData = [:]
            cloudUsageLoadError = error.localizedDescription
        }
    }

    private func syncUsageDataToCloud(_ usageData: UsageData, sampledAt: Date) {
        guard cloudSyncEnabled else { return }

        let historiesSnapshot = utilizationHistories

        Task { @MainActor in
            await CloudSyncService.shared.syncUsageData(
                usageData,
                sampledAt: sampledAt,
                utilizationHistories: historiesSnapshot
            )
        }
    }

    /// App 启动时主动 flush 一次堆积队列（fire-and-forget）
    func flushPendingCloudSyncQueue() {
        guard cloudSyncEnabled else { return }
        Task { @MainActor in
            await CloudSyncService.shared.flushPendingQueue()
        }
    }

    /// 跟 StatusBarController displayOrder 对齐：codex 优先。
    /// `combinedUsageData` 输出的 `provider` 字段是"哪个 provider 在结果里最重要"，
    /// 跟数据真实来源保持一致。`WarningPanelController` 等下游仍按自己逻辑取订阅信息。
    private static let combinedProviderPriority: [UsageProvider] = [.codex, .miniMax, .glm]

    private func combinedUsageData(from providerData: Dictionary<UsageProvider, UsageData>.Values, timestamp: Date) -> UsageData? {
        let models = providerData.flatMap(\.models)
        guard models.isEmpty == false else { return nil }

        let primaryProvider = Self.combinedProviderPriority
            .first(where: { provider in providerData.contains(where: { $0.provider == provider }) })
            ?? .codex

        let subscribeTitle = providerData
            .first(where: { $0.provider == .miniMax })?.subscribeTitle
        let subscribeEndTime = providerData
            .first(where: { $0.provider == .miniMax })?.subscribeEndTime

        return UsageData(
            provider: primaryProvider,
            remains: models.filter(\.isCurrentIntervalAvailable).count,
            total: models.count,
            timestamp: timestamp,
            models: models,
            subscribeTitle: subscribeTitle,
            subscribeEndTime: subscribeEndTime
        )
    }

    private func menuBarCandidateModels(from models: [ModelUsageData], now: Date) -> [ModelUsageData] {
        models
            .filter { isMenuBarCandidate($0, now: now) }
            .sorted { lhs, rhs in
                let lhsSourcePriority = menuBarSourcePriority(lhs.parsedDetail.source)
                let rhsSourcePriority = menuBarSourcePriority(rhs.parsedDetail.source)
                if lhsSourcePriority != rhsSourcePriority {
                    return lhsSourcePriority < rhsSourcePriority
                }

                let lhsReset = lhs.endTime ?? .distantFuture
                let rhsReset = rhs.endTime ?? .distantFuture

                if lhsReset != rhsReset {
                    return lhsReset < rhsReset
                }
                if lhs.currentIntervalPercentageRemaining != rhs.currentIntervalPercentageRemaining {
                    return lhs.currentIntervalPercentageRemaining < rhs.currentIntervalPercentageRemaining
                }
                return lhs.displayName < rhs.displayName
            }
    }

    private func preferredMenuBarFallbackModels(from models: [ModelUsageData], now: Date) -> [ModelUsageData] {
        let candidates = menuBarCandidateModels(from: models, now: now)
        let usedCandidates = candidates.filter { $0.currentIntervalUsedCount > 0 }
        return usedCandidates.isEmpty ? candidates : usedCandidates
    }

    private func isMenuBarCandidate(_ model: ModelUsageData, now: Date) -> Bool {
        guard model.isCurrentIntervalAvailable else { return false }
        guard let endTime = model.endTime else { return true }
        return endTime > now
    }

    private func menuBarSourcePriority(_ source: String?) -> Int {
        switch source {
        case "OAuth", "Mix", "Codex CLI", "OpenAI Web":
            return 0
        case "Cloud":
            return 1
        default:
            return 0
        }
    }

    private func recordSamples(from data: UsageData, timestamp: Date) {
        var nextSamples: [String: [ModelQuotaSample]] = [:]

        for model in data.models {
            guard model.isShortCurrentInterval,
                  let startTime = model.startTime,
                  let endTime = model.endTime else {
                continue
            }

            let clampedTimestamp = min(max(timestamp, startTime), endTime)
            let newSample = ModelQuotaSample(
                timestamp: clampedTimestamp,
                remaining: model.currentIntervalRemaining,
                percent: model.currentIntervalRemainingPercent
            )

            var samples = (modelQuotaSamples[model.id] ?? [])
                .filter { $0.timestamp >= startTime && $0.timestamp <= endTime }
                .sorted { $0.timestamp < $1.timestamp }

            if let lastSample = samples.last,
               abs(lastSample.timestamp.timeIntervalSince1970 - newSample.timestamp.timeIntervalSince1970) < 1 {
                samples[samples.count - 1] = newSample
            } else {
                samples.append(newSample)
            }

            nextSamples[model.id] = samples
        }

        modelQuotaSamples = nextSamples
    }

    private func checkThreshold() {
        guard let data = usageData else {
            showWarningPanel = false
            return
        }

        showWarningPanel =
            data.exhaustedModelsCount > 0 ||
            data.lowModelsCount(threshold: warningThreshold) > 0
    }

#if DEBUG
    /// Generates deterministic mock chart points: 5h range, 1-minute ticks,
    /// descending from 4500 to the current remaining value at the current time.
    private func syntheticMinuteSamples(
        for model: ModelUsageData,
        startTime: Date,
        endTime: Date
    ) -> [ModelQuotaSample] {
        let clampedNow = min(max(Date(), startTime), endTime)
        let startRemaining = model.currentIntervalTotal > 0
            ? min(4500, model.currentIntervalTotal)
            : 4500
        let endRemaining = max(0, min(model.currentIntervalRemaining, startRemaining))

        let elapsed = max(clampedNow.timeIntervalSince(startTime), 0)
        let minuteCount = Int(elapsed / 60)
        let base = startTime.timeIntervalSince1970

        var samples: [ModelQuotaSample] = (0...minuteCount).map { minute in
            let ratio = minuteCount > 0 ? Double(minute) / Double(minuteCount) : 0
            let interpolated = Double(startRemaining) + Double(endRemaining - startRemaining) * ratio
            return ModelQuotaSample(
                timestamp: Date(timeIntervalSince1970: base + Double(minute) * 60),
                remaining: Int(interpolated.rounded())
            )
        }

        if samples.last?.timestamp != clampedNow {
            samples.append(ModelQuotaSample(timestamp: clampedNow, remaining: endRemaining))
        } else if !samples.isEmpty {
            samples[samples.count - 1] = ModelQuotaSample(timestamp: clampedNow, remaining: endRemaining)
        }

        return samples
    }
#endif
}
