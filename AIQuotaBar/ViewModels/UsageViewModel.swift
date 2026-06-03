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
    var providerErrors: [UsageProvider: UsageError] = [:]
    var error: UsageError?
    var isLoading: Bool = false
    var lastRefreshTime: Date?
    var showWarningPanel: Bool = false
    private(set) var modelQuotaSamples: [String: [ModelQuotaSample]] = [:]

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

    var cloudSyncEndpointURL: String {
        didSet {
            saveCloudSyncSettings()
        }
    }

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
        UsageProvider.allCases.compactMap { providerUsageData[$0] }
    }

    // MARK: - Private

    private var timer: Timer?
    private var lastCloudRestoreAt: Date?

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
        self.cloudSyncEndpointURL = cloudSyncSettings.endpointURLString

        updateStatusBarText()
    }

    // MARK: - Public Methods

    func refresh() async {
        guard !isLoading else { return }

        isLoading = true
        error = nil
        providerErrors = [:]

        let providers = configuredProviders
        guard providers.isEmpty == false else {
            usageData = nil
            providerUsageData = [:]
            error = .notConfigured
            updateStatusBarText()
            isLoading = false
            return
        }

        var nextProviderData: [UsageProvider: UsageData] = [:]
        var nextProviderErrors: [UsageProvider: UsageError] = [:]
        let sampleTimestamp = Date()

        for provider in providers {
            do {
                let data = try await UsageService.shared.fetchUsage(provider: provider)
                nextProviderData[provider] = data
            } catch let usError as UsageError {
                nextProviderErrors[provider] = usError
            } catch {
                nextProviderErrors[provider] = .networkError(error)
            }
        }

        providerUsageData = nextProviderData
        providerErrors = nextProviderErrors
        usageData = combinedUsageData(from: nextProviderData.values, timestamp: sampleTimestamp)
        error = usageData == nil ? nextProviderErrors.values.first : nil
        if let usageData {
            lastRefreshTime = sampleTimestamp
            recordSamples(from: usageData, timestamp: sampleTimestamp)
            syncUsageDataToCloud(usageData, sampledAt: sampleTimestamp)
        }
        updateStatusBarText()
        checkThreshold()

        isLoading = false

        // 节流触发云恢复：首次 refresh 必然触发，之后每 10 分钟跨多个 refresh 周期再触发一次。
        // 不阻塞 refresh，restore 在自己的 task 里跑；失败也跟普通 refresh 错误一样静默。
        let elapsedSinceLastRestore = lastCloudRestoreAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let shouldTriggerRestore = isCloudSyncConfigured
            && elapsedSinceLastRestore >= Self.cloudRestoreThrottleInterval
        if shouldTriggerRestore {
            await restoreFromCloud()
        }
    }

    /// 云同步是否处于"配置好"状态：开关打开、endpoint 非空、token 存在。
    /// 全部命中才会触发云恢复；任一缺失就 no-op，不报错、不记日志。
    private var isCloudSyncConfigured: Bool {
        guard cloudSyncEnabled else { return false }
        let endpoint = cloudSyncEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else { return false }
        let token = KeychainService.shared.getCloudSyncToken()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !token.isEmpty
    }

    private static let cloudRestoreThrottleInterval: TimeInterval = 600

    /// 从云端拉取最近一批 quota 样本，按 `modelID` 合并到 `modelQuotaSamples`。
    /// 关键：merge 不是 replace — 用 1s timestamp 去重（对齐 `recordSamples:451` 的 `< 1` 规则），
    /// 否则每次启动都会把第一次 refresh 刚写入的本地样本覆盖掉。
    /// 只补当前 5h 窗口内的样本（`sampledAt >= startTime && <= endTime`），跨窗口不补。
    /// percent 字段优先用云端存的；云端没存（早期 payload）但 model 处于 Codex 5h
    /// 风格（`valueSuffix == "%"`）时，fallback 把 `remaining` 复制成 `percent`，
    /// 避免历史 tooltip 显示错。其它 model 不复制（MiniMax 的 `remaining` 是真实计数，不是 percent）。
    /// 全部静默：失败/配置缺失都不打扰用户。
    func restoreFromCloud() async {
        guard isCloudSyncConfigured else { return }

        let shortModels = providerUsageSections
            .flatMap(\.models)
            .filter(\.isShortCurrentInterval)
        guard !shortModels.isEmpty else { return }

        let startedAt = Date()
        let samplesByID: [String: [ModelQuotaSample]]
        do {
            samplesByID = try await CloudSyncService.shared.fetchRecentQuotaSamples(limit: 2000)
        } catch {
#if DEBUG
            print("Cloud restore failed: \(error.localizedDescription)")
#endif
            return
        }

        var next = modelQuotaSamples
        var totalRestored = 0
        var restoredModels = 0

        for model in shortModels {
            guard let startTime = model.startTime, let endTime = model.endTime else { continue }
            let existing = next[model.id] ?? []
            let cloudSamples = samplesByID[model.id] ?? []

            var merged: [Int: ModelQuotaSample] = [:]
            for sample in existing {
                merged[Int(sample.timestamp.timeIntervalSince1970)] = sample
            }
            for sample in cloudSamples {
                guard sample.timestamp >= startTime, sample.timestamp <= endTime else { continue }
                let withPercent: ModelQuotaSample
                if sample.percent != nil {
                    withPercent = sample
                } else if model.valueSuffix == "%", model.currentIntervalRemainingPercent != nil {
                    // 兼容早期 cloud payload（没存 percent）：Codex 5h 的 `remaining`
                    // 本身就是 percent 数字（valueSuffix=="%" 标识），复制一份给 tooltip。
                    withPercent = ModelQuotaSample(
                        timestamp: sample.timestamp,
                        remaining: sample.remaining,
                        percent: sample.remaining
                    )
                } else {
                    withPercent = sample
                }
                merged[Int(withPercent.timestamp.timeIntervalSince1970)] = withPercent
            }

            if merged.isEmpty == false {
                let sorted = merged.values.sorted { $0.timestamp < $1.timestamp }
                next[model.id] = sorted
                totalRestored += sorted.count
                restoredModels += 1
            }
        }

        modelQuotaSamples = next
        lastCloudRestoreAt = Date()

#if DEBUG
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        print("Cloud restore: \(totalRestored) samples for \(restoredModels) models (after \(elapsedMs)ms)")
#endif
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

    func saveCloudSyncToken(_ token: String) -> Bool {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedToken.isEmpty {
            return KeychainService.shared.deleteCloudSyncToken()
        }
        return KeychainService.shared.saveCloudSyncToken(trimmedToken)
    }

    func cloudSyncToken() -> String {
        KeychainService.shared.getCloudSyncToken() ?? ""
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

    // MARK: - Private Methods

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(refreshInterval), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    private func saveCloudSyncSettings() {
        CloudSyncSettings(
            isEnabled: cloudSyncEnabled,
            endpointURLString: cloudSyncEndpointURL,
            deviceID: CloudSyncSettings.current.deviceID
        ).save()
    }

    private func syncUsageDataToCloud(_ usageData: UsageData, sampledAt: Date) {
        guard cloudSyncEnabled else { return }

        Task {
            do {
                try await CloudSyncService.shared.syncUsageData(usageData, sampledAt: sampledAt)
            } catch {
#if DEBUG
                print("Cloud sync failed: \(error.localizedDescription)")
#endif
            }
        }
    }

    private func combinedUsageData(from providerData: Dictionary<UsageProvider, UsageData>.Values, timestamp: Date) -> UsageData? {
        let models = providerData.flatMap(\.models)
        guard models.isEmpty == false else { return nil }

        let subscribeTitle = providerData
            .first(where: { $0.provider == .miniMax })?.subscribeTitle
        let subscribeEndTime = providerData
            .first(where: { $0.provider == .miniMax })?.subscribeEndTime

        return UsageData(
            provider: .miniMax,
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
