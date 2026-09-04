import Foundation
import AppKit

/// Main view model managing usage state and refresh logic
@MainActor
@Observable
final class UsageViewModel {
    // MARK: - Published State

    var usageData: UsageData? {
        didSet {
            checkThreshold()
            updateStatusBarText()
        }
    }
    var providerUsageData: [UsageProvider: UsageData] = [:]
    var cloudProviderUsageData: [UsageProvider: UsageData] = [:]
    var cloudUsageLoadError: String?
    var providerErrors: [UsageProvider: UsageError] = [:]
    var error: UsageError?
    var isLoading: Bool = false
    private(set) var isMenuBarSelfTesting: Bool = false
    var lastRefreshTime: Date?
    var showWarningPanel: Bool = false
    private(set) var modelQuotaSamples: [String: [ModelQuotaSample]] = [:]
    private var mobileDashboardSelectedModelKeys =
        Set<MobileDashboardModelSelectionKey>()
    private(set) var cloudModelQuotaSamples: [String: [ModelQuotaSample]] = [:]
    private(set) var utilizationHistories: [UsageProvider: ModelUtilizationStoreData] = [:]
    private let utilizationStore = ModelUtilizationHistoryStore.shared
    private let quotaSampleStore = ModelQuotaSampleStore.shared
    private let utilizationSampleThrottle: TimeInterval = 3600

    // MARK: - Settings

    var refreshInterval: Int {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
            invalidateCycleEndTimer()
            restartTimer()
        }
    }

    var warningThreshold: Double {
        didSet {
            UserDefaults.standard.set(warningThreshold, forKey: "warningThreshold")
            checkThreshold()
            updateStatusBarText()
        }
    }

    var warningThresholdEnabled: Bool {
        didSet {
            UserDefaults.standard.set(warningThresholdEnabled, forKey: "warningThresholdEnabled")
            updateStatusBarText()
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

    var menuBarContentSelection: MenuBarContentSelection {
        didSet {
            UserDefaults.standard.set(menuBarContentSelection.rawValue, forKey: MenuBarContentSelection.storageKey)
            updateStatusBarText()
        }
    }

    var menuBarAppearance: MenuBarAppearance {
        didSet {
            UserDefaults.standard.set(menuBarAppearance.rawValue, forKey: MenuBarAppearance.storageKey)
            updateStatusBarText()
        }
    }

    var menuBarPaceDisplayMode: MenuBarPaceDisplayMode {
        didSet {
            UserDefaults.standard.set(
                menuBarPaceDisplayMode.rawValue,
                forKey: MenuBarPaceDisplayMode.storageKey)
        }
    }

    var menuBarRingQuotaWindow: MenuBarRingQuotaWindow {
        didSet {
            UserDefaults.standard.set(
                menuBarRingQuotaWindow.rawValue,
                forKey: MenuBarRingQuotaWindow.storageKey)
            updateStatusBarText()
        }
    }

    var menuBarReserveQuotaWindow: MenuBarReserveQuotaWindow {
        didSet {
            UserDefaults.standard.set(
                menuBarReserveQuotaWindow.rawValue,
                forKey: MenuBarReserveQuotaWindow.storageKey)
            updateStatusBarText()
        }
    }

    var menuBarCompactHorizontalPadding: Double {
        didSet {
            let clamped = MenuBarCompactLayoutPreferences.horizontalPadding(
                menuBarCompactHorizontalPadding)
            if clamped != menuBarCompactHorizontalPadding {
                menuBarCompactHorizontalPadding = clamped
                return
            }
            UserDefaults.standard.set(
                clamped,
                forKey: MenuBarCompactLayoutPreferences.horizontalPaddingKey)
        }
    }

    var menuBarCompactRingSpacing: Double {
        didSet {
            let clamped = MenuBarCompactLayoutPreferences.ringSpacing(
                menuBarCompactRingSpacing)
            if clamped != menuBarCompactRingSpacing {
                menuBarCompactRingSpacing = clamped
                return
            }
            UserDefaults.standard.set(
                clamped,
                forKey: MenuBarCompactLayoutPreferences.ringSpacingKey)
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

    var quotaForecastLookbackIntervals: Int {
        didSet {
            UserDefaults.standard.set(
                quotaForecastLookbackIntervals,
                forKey: Self.quotaForecastLookbackIntervalsKey)
        }
    }

    var leftClickMenuDisplayPreferences: LeftClickMenuDisplayPreferences {
        didSet {
            leftClickMenuDisplayPreferences.save()
        }
    }

    var quotaChartDisplayPreferences: QuotaChartDisplayPreferences {
        didSet {
            quotaChartDisplayPreferences.save()
        }
    }

    var cloudCurrentWindowVisibilityLimit: CloudDataVisibilityLimit {
        didSet {
            UserDefaults.standard.set(cloudCurrentWindowVisibilityLimit.rawValue, forKey: Self.cloudCurrentWindowVisibilityLimitKey)
        }
    }

    var cloudShortCyclesVisibilityLimit: CloudDataVisibilityLimit {
        didSet {
            UserDefaults.standard.set(cloudShortCyclesVisibilityLimit.rawValue, forKey: Self.cloudShortCyclesVisibilityLimitKey)
        }
    }

    var cloudWeeklyCyclesVisibilityLimit: CloudDataVisibilityLimit {
        didSet {
            UserDefaults.standard.set(cloudWeeklyCyclesVisibilityLimit.rawValue, forKey: Self.cloudWeeklyCyclesVisibilityLimitKey)
        }
    }

    var cloudDataRetentionLimit: CloudDataRetentionLimit {
        didSet {
            UserDefaults.standard.set(cloudDataRetentionLimit.rawValue, forKey: Self.cloudDataRetentionLimitKey)
        }
    }

    private static let utilizationHistoryModeKey = "utilizationHistoryMode"
    private static let quotaForecastLookbackIntervalsKey =
        "quotaForecastLookbackIntervals"
    private static let cloudCurrentWindowVisibilityLimitKey = "cloudCurrentWindowVisibilityLimit"
    private static let cloudShortCyclesVisibilityLimitKey = "cloudShortCyclesVisibilityLimit"
    private static let cloudWeeklyCyclesVisibilityLimitKey = "cloudWeeklyCyclesVisibilityLimit"
    private static let cloudDataRetentionLimitKey = CloudDataRetentionLimit.storageKey

    // MARK: - Computed Properties

    var statusBarText: String = "..."
    private(set) var menuBarSnapshot = MenuBarSnapshot(
        provider: .codex,
        modelName: nil,
        remainingPercent: nil,
        ringPercent: nil,
        paceDeltaPercent: nil,
        resetsAt: nil,
        state: .loading,
        isLowQuota: false,
        tooltip: "")
    private(set) var menuBarSnapshots = [MenuBarSnapshot(
        provider: .codex,
        modelName: nil,
        remainingPercent: nil,
        ringPercent: nil,
        paceDeltaPercent: nil,
        resetsAt: nil,
        state: .loading,
        isLowQuota: false,
        tooltip: "")]

    var availableModels: [ModelUsageData] {
        guard let data = usageData else { return [] }
        return menuBarCandidateModels(from: data.models, now: Date())
    }

    private func updateStatusBarText() {
        let now = Date()
        let allModels = usageData?.models ?? []
        let candidates = menuBarCandidateModels(from: allModels, now: now)

        guard let primary = selectedMenuBarModel(from: candidates) else {
            let provider = fallbackMenuBarProvider()
            let failed = providerErrors[provider] != nil || (error != nil && usageData == nil)
            let state: MenuBarSnapshotState = failed ? .failed : (isLoading || usageData == nil ? .loading : .unavailable)
            let snapshot = makeMenuBarStateSnapshot(
                provider: provider,
                state: state)
            menuBarSnapshot = snapshot
            menuBarSnapshots = compactMenuBarStateSnapshots(
                fallback: snapshot,
                defaultState: state)
            statusBarText = "\(provider.displayName)\n\(statusBarStateText(state))"
            return
        }

        let primarySnapshot = makeMenuBarSnapshot(
            primary: primary,
            models: allModels)
        menuBarSnapshot = primarySnapshot
        menuBarSnapshots = compactMenuBarSnapshots(
            primarySnapshot: primarySnapshot,
            candidates: candidates,
            models: allModels)

        if let automaticText = detailedAutomaticStatusBarText(
            primary: primary,
            candidates: candidates,
            metricModels: allModels
        ) {
            statusBarText = automaticText
            return
        }

        statusBarText = [
            primary.provider.displayName,
            primary.formattedStatusBarLine(
                paceSource: menuBarPaceSource(
                    for: primary,
                    models: allModels))
        ].joined(separator: "\n")
    }

    private func compactMenuBarSnapshots(
        primarySnapshot: MenuBarSnapshot,
        candidates: [ModelUsageData],
        models: [ModelUsageData]
    ) -> [MenuBarSnapshot] {
        guard menuBarAppearance == .compactRing,
              menuBarContentSelection == .all
                || menuBarContentSelection == .automatic else {
            return [primarySnapshot]
        }

        let displayOrder: [UsageProvider] = [.codex, .kimi]
        let snapshots = displayOrder.compactMap { provider -> MenuBarSnapshot? in
            guard let primary = pickPrimary(
                from: candidates.filter { $0.provider == provider }) else {
                return nil
            }
            return makeMenuBarSnapshot(primary: primary, models: models)
        }
        return snapshots
    }

    private func compactMenuBarStateSnapshots(
        fallback: MenuBarSnapshot,
        defaultState: MenuBarSnapshotState
    ) -> [MenuBarSnapshot] {
        guard menuBarAppearance == .compactRing,
              menuBarContentSelection == .all
                || menuBarContentSelection == .automatic else {
            return [fallback]
        }

        let registered = taskProtectionProviders
        let providers = [UsageProvider.codex, .kimi].filter {
            registered.contains($0)
        }
        return (providers.isEmpty ? [.codex] : providers).map { provider in
            let state: MenuBarSnapshotState = providerErrors[provider] == nil
                ? defaultState
                : .failed
            return makeMenuBarStateSnapshot(provider: provider, state: state)
        }
    }

    private func makeMenuBarStateSnapshot(
        provider: UsageProvider,
        state: MenuBarSnapshotState
    ) -> MenuBarSnapshot {
        MenuBarSnapshot(
            provider: provider,
            modelName: nil,
            remainingPercent: nil,
            ringPercent: nil,
            paceDeltaPercent: nil,
            resetsAt: nil,
            state: state,
            isLowQuota: false,
            tooltip: menuBarStateTooltip(provider: provider, state: state))
    }

    private func makeMenuBarSnapshot(
        primary: ModelUsageData,
        models: [ModelUsageData]
    ) -> MenuBarSnapshot {
        let paceSource = menuBarPaceSource(for: primary, models: models)
        let paceDelta = paceSource.currentIntervalPaceDeltaPercent
        let remaining = primary.currentIntervalPercentageRemaining
        let ringPercent = menuBarRingPercent(for: primary, models: models)
        let warningLimit = warningThresholdEnabled ? warningThreshold : 20

        return MenuBarSnapshot(
            provider: primary.provider,
            modelName: primary.modelName,
            remainingPercent: remaining,
            ringPercent: ringPercent,
            paceDeltaPercent: paceDelta,
            resetsAt: primary.endTime,
            state: .ready,
            isLowQuota: remaining <= warningLimit,
            tooltip: menuBarReadyTooltip(
                primary: primary,
                weeklyRemainingPercent: menuBarRingQuotaWindow == .weekly
                    && (primary.provider == .codex || primary.provider == .kimi)
                        ? ringPercent
                        : nil,
                paceDelta: paceDelta))
    }

    /// Detailed + Automatic 有足够数据时每行显示一家。
    private func detailedAutomaticStatusBarText(
        primary: ModelUsageData,
        candidates: [ModelUsageData],
        metricModels: [ModelUsageData]
    ) -> String? {
        guard menuBarAppearance == .detailedText,
              menuBarContentSelection == .all
                || menuBarContentSelection == .automatic else {
            return nil
        }

        let otherPrimaries = UsageProvider.allCases
            .filter { $0 != primary.provider }
            .compactMap { provider in
                pickPrimary(from: candidates.filter { $0.provider == provider })
            }
        guard let secondary = otherPrimaries.first else { return nil }

        return [primary, secondary]
            .map { model in
                model.formattedStatusBarLine(
                    providerInitial: menuBarProviderInitial(model.provider),
                    paceSource: menuBarPaceSource(for: model, models: metricModels))
            }
            .joined(separator: "\n")
    }

    private func menuBarProviderInitial(_ provider: UsageProvider) -> String {
        switch provider {
        case .codex: return "C"
        case .miniMax: return "M"
        case .glm: return "G"
        case .kimi: return "K"
        }
    }

    /// 选 status bar 主显示 model:
    /// - Codex/Kimi 选 "5h" model(显示 5h 短周期剩余%/reset)
    /// - 其他 provider 取 candidates 第一个(已按 reset 排序)
    private func pickPrimary(from candidates: [ModelUsageData]) -> ModelUsageData? {
        if let shortWindow = candidates.first(where: {
            ($0.provider == .codex || $0.provider == .kimi)
                && $0.modelName.localizedCaseInsensitiveContains("5h")
        }) {
            return shortWindow
        }
        return candidates.first
    }

    /// Finds a provider's seven-day window, including an exhausted one so the
    /// outer ring can correctly render an empty arc.
    private func weeklyModel(
        for provider: UsageProvider,
        in models: [ModelUsageData]
    ) -> ModelUsageData? {
        models.first(where: { model in
            guard model.provider == provider else { return false }
            let name = model.modelName.lowercased()
            return name.contains("weekly") || name == "7d"
        })
    }

    private func selectedMenuBarModel(from candidates: [ModelUsageData]) -> ModelUsageData? {
        if let fixedProvider = menuBarContentSelection.provider {
            return pickPrimary(from: candidates.filter { $0.provider == fixedProvider })
        }

        let providerPrimaries = UsageProvider.allCases.compactMap { provider in
            pickPrimary(from: candidates.filter { $0.provider == provider })
        }
        return providerPrimaries.min { lhs, rhs in
            isMoreUrgentMenuBarModel(lhs, than: rhs, candidates: candidates)
        }
    }

    private func isMoreUrgentMenuBarModel(
        _ lhs: ModelUsageData,
        than rhs: ModelUsageData,
        candidates: [ModelUsageData]
    ) -> Bool {
        let warningLimit = warningThresholdEnabled ? warningThreshold : 20
        let lhsLow = lhs.currentIntervalPercentageRemaining <= warningLimit
        let rhsLow = rhs.currentIntervalPercentageRemaining <= warningLimit
        if lhsLow != rhsLow { return lhsLow }

        let lhsDelta = menuBarPaceSource(for: lhs, models: candidates).currentIntervalPaceDeltaPercent
        let rhsDelta = menuBarPaceSource(for: rhs, models: candidates).currentIntervalPaceDeltaPercent
        let lhsDeficit = (lhsDelta ?? 0) < -2
        let rhsDeficit = (rhsDelta ?? 0) < -2
        if lhsDeficit != rhsDeficit { return lhsDeficit }

        if lhs.currentIntervalPercentageRemaining != rhs.currentIntervalPercentageRemaining {
            return lhs.currentIntervalPercentageRemaining < rhs.currentIntervalPercentageRemaining
        }
        return (lhs.endTime ?? .distantFuture) < (rhs.endTime ?? .distantFuture)
    }

    /// Codex and Kimi can independently source the split center's pace from
    /// their weekly or current window. Missing weekly data falls back safely.
    private func menuBarPaceSource(
        for primary: ModelUsageData,
        models: [ModelUsageData]
    ) -> ModelUsageData {
        guard primary.provider == .codex || primary.provider == .kimi,
              menuBarReserveQuotaWindow.resolved(
                outerRing: menuBarRingQuotaWindow) == .weekly else {
            return primary
        }
        return weeklyModel(
            for: primary.provider,
            in: models.filter {
                $0.normalizedAccountName == primary.normalizedAccountName
            })
            ?? primary
    }

    /// Codex and Kimi can source the outer arc from either their weekly quota
    /// or the selected short/current quota. Providers without weekly data keep
    /// their existing current-window behavior.
    private func menuBarRingPercent(
        for primary: ModelUsageData,
        models: [ModelUsageData]
    ) -> Double? {
        guard menuBarRingQuotaWindow == .weekly,
              primary.provider == .codex || primary.provider == .kimi else {
            return primary.currentIntervalPercentageRemaining
        }
        return weeklyModel(
            for: primary.provider,
            in: models.filter {
                $0.normalizedAccountName == primary.normalizedAccountName
            })?
            .currentIntervalPercentageRemaining
    }

    private func fallbackMenuBarProvider() -> UsageProvider {
        if let fixedProvider = menuBarContentSelection.provider {
            return fixedProvider
        }
        return configuredProviders.first ?? .codex
    }

    private func statusBarStateText(_ state: MenuBarSnapshotState) -> String {
        appLanguage.menuBarStateText(state)
    }

    private func menuBarStateTooltip(provider: UsageProvider, state: MenuBarSnapshotState) -> String {
        appLanguage.menuBarStateTooltip(provider: provider, state: state)
    }

    private func menuBarReadyTooltip(
        primary: ModelUsageData,
        weeklyRemainingPercent: Double?,
        paceDelta: Double?
    ) -> String {
        appLanguage.menuBarReadyTooltip(
            provider: primary.provider,
            modelName: primary.modelName,
            remainingText: primary.currentIntervalRemainingText,
            weeklyRemainingPercent: weeklyRemainingPercent,
            paceDeltaPercent: paceDelta,
            resetText: primary.statusBarResetText)
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

    /// Providers whose local task lifecycle can participate in sleep
    /// protection. Unlike quota refresh, Codex is included only when a local
    /// account, auth file, or running Codex app/CLI is actually present.
    var taskProtectionProviders: Set<UsageProvider> {
        var providers = Set<UsageProvider>()
        if hasLocalCodexRegistration {
            providers.insert(.codex)
        }
        if KeychainService.shared.hasCredential(for: .kimi)
            || KimiService.shared.hasCLICredential {
            providers.insert(.kimi)
        }
        return providers
    }

    private var hasLocalCodexRegistration: Bool {
        if CodexAccountCoordinator.shared.hasManagedAccount {
            return true
        }
        let environment = ProcessInfo.processInfo.environment
        let codexHome: URL
        if let configured = environment["CODEX_HOME"],
           !configured.isEmpty {
            codexHome = URL(
                fileURLWithPath: configured,
                isDirectory: true)
        } else {
            codexHome = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        }
        return FileManager.default.fileExists(
            atPath: codexHome.appendingPathComponent("auth.json").path)
    }

    /// 判断 provider 是否应该被纳入刷新与下拉菜单。
    /// MiniMax 走 Keychain；Codex 由 codexbar 的 managed account store 自管，
    /// 凭证在 `~/.codex`（CLI）或 `~/.codexbar`（managed store）。
    /// 这里始终让 Codex 算 configured：fetch 时 codexbar 自己会返回 unauthorized 之类的错误，
    /// dropdown 不会展示该 section，Settings 仍能进 Codex 段做添加/移除操作。
    private func isConfigured(_ provider: UsageProvider) -> Bool {
        switch provider {
        case .codex:
            return true
        case .kimi:
            return KeychainService.shared.hasCredential(for: .kimi)
                || KimiService.shared.hasCLICredential
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

    var leftClickMenuUsageSections: [UsageData] {
        providerUsageSections.compactMap { data in
            let visibleModels = data.models.filter {
                leftClickMenuDisplayPreferences.isModelVisible($0)
            }
            return visibleModels.isEmpty ? nil : data.withModels(visibleModels)
        }
    }

    var hasHiddenLeftClickMenuItems: Bool {
        leftClickMenuDisplayPreferences.hasHiddenItems
    }

    // MARK: - Private

    private var timer: Timer?
    private var cycleEndTimer: Timer?
    private var cycleEndFireDate: Date?
    /// 周期结束后触发对齐刷新的延迟（秒），避免踩在服务端重置生效的边界上。
    private let cycleEndRefreshDelay: TimeInterval = 15

    // MARK: - Initialization

    init() {
        self.refreshInterval = UserDefaults.standard.object(forKey: "refreshInterval") as? Int ?? 600
        self.warningThreshold = UserDefaults.standard.double(forKey: "warningThreshold") > 0
            ? UserDefaults.standard.double(forKey: "warningThreshold")
            : 20.0
        self.warningThresholdEnabled = UserDefaults.standard.object(forKey: "warningThresholdEnabled") as? Bool ?? false
        self.autoRefreshOnLaunch = UserDefaults.standard.object(forKey: "autoRefreshOnLaunch") as? Bool ?? true
        self.appLanguage = UserDefaults.standard.string(forKey: AppLanguage.storageKey)
            .flatMap(AppLanguage.init(rawValue:))
            ?? AppLanguage.fallback
        self.launchAtLogin = UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool ?? false
        self.menuBarContentSelection = UserDefaults.standard.string(forKey: MenuBarContentSelection.storageKey)
            .flatMap(MenuBarContentSelection.init(rawValue:))
            ?? .automatic
        self.menuBarAppearance = UserDefaults.standard.string(forKey: MenuBarAppearance.storageKey)
            .flatMap(MenuBarAppearance.init(rawValue:))
            ?? .detailedText
        self.menuBarPaceDisplayMode = UserDefaults.standard.string(forKey: MenuBarPaceDisplayMode.storageKey)
            .flatMap(MenuBarPaceDisplayMode.init(rawValue:))
            ?? .continuous
        self.menuBarRingQuotaWindow = UserDefaults.standard.string(
            forKey: MenuBarRingQuotaWindow.storageKey)
            .flatMap(MenuBarRingQuotaWindow.init(rawValue:))
            ?? .weekly
        self.menuBarReserveQuotaWindow = UserDefaults.standard.string(
            forKey: MenuBarReserveQuotaWindow.storageKey)
            .flatMap(MenuBarReserveQuotaWindow.init(rawValue:))
            ?? .synchronized
        self.menuBarCompactHorizontalPadding =
            MenuBarCompactLayoutPreferences.horizontalPadding(
                UserDefaults.standard.object(
                    forKey: MenuBarCompactLayoutPreferences.horizontalPaddingKey)
                    as? Double
                    ?? MenuBarCompactLayoutPreferences.defaultHorizontalPadding)
        self.menuBarCompactRingSpacing =
            MenuBarCompactLayoutPreferences.ringSpacing(
                UserDefaults.standard.object(
                    forKey: MenuBarCompactLayoutPreferences.ringSpacingKey)
                    as? Double
                    ?? MenuBarCompactLayoutPreferences.defaultRingSpacing)
        let cloudSyncSettings = CloudSyncSettings.current
        self.cloudSyncEnabled = cloudSyncSettings.isEnabled
        self.utilizationHistoryMode = UserDefaults.standard.string(forKey: Self.utilizationHistoryModeKey)
            .flatMap(UtilizationHistoryMode.init(rawValue:))
            ?? .includeCurrent
        self.quotaForecastLookbackIntervals = min(max(
            UserDefaults.standard.object(
                forKey: Self.quotaForecastLookbackIntervalsKey) as? Int ?? 3,
            1), 5)
        self.leftClickMenuDisplayPreferences = LeftClickMenuDisplayPreferences.load()
        self.quotaChartDisplayPreferences = QuotaChartDisplayPreferences.load()
        self.cloudCurrentWindowVisibilityLimit = UserDefaults.standard.string(forKey: Self.cloudCurrentWindowVisibilityLimitKey)
            .flatMap(CloudDataVisibilityLimit.init(rawValue:))
            ?? .oneHour
        self.cloudShortCyclesVisibilityLimit = UserDefaults.standard.string(forKey: Self.cloudShortCyclesVisibilityLimitKey)
            .flatMap(CloudDataVisibilityLimit.init(rawValue:))
            ?? .fiveHours
        self.cloudWeeklyCyclesVisibilityLimit = UserDefaults.standard.string(forKey: Self.cloudWeeklyCyclesVisibilityLimitKey)
            .flatMap(CloudDataVisibilityLimit.init(rawValue:))
            ?? .oneWeek
        self.cloudDataRetentionLimit = .current

        loadUtilizationHistories()
        modelQuotaSamples = quotaSampleStore.loadAll()
        updateStatusBarText()
        if cloudSyncEnabled {
            Task { @MainActor in
                await refreshCloudUsageData()
            }
        }
    }

    // MARK: - Public Methods

    func isLeftClickMenuAccountVisible(_ key: LeftClickMenuAccountKey) -> Bool {
        leftClickMenuDisplayPreferences.isAccountVisible(key)
    }

    func isLeftClickMenuModelVisible(_ model: ModelUsageData) -> Bool {
        leftClickMenuDisplayPreferences.isModelVisible(model)
    }

    func setLeftClickMenuAccountVisible(
        _ isVisible: Bool,
        key: LeftClickMenuAccountKey
    ) {
        var preferences = leftClickMenuDisplayPreferences
        preferences.setAccountVisible(isVisible, key: key)
        leftClickMenuDisplayPreferences = preferences
    }

    func setLeftClickMenuModelVisible(
        _ isVisible: Bool,
        model: ModelUsageData
    ) {
        var preferences = leftClickMenuDisplayPreferences
        preferences.setModelVisible(
            isVisible,
            key: model.mobileDashboardSelectionKey)
        leftClickMenuDisplayPreferences = preferences
    }

    func showAllLeftClickMenuItems() {
        var preferences = leftClickMenuDisplayPreferences
        preferences.showAll()
        leftClickMenuDisplayPreferences = preferences
    }

    func quotaChartDisplayMode(for model: ModelUsageData) -> QuotaChartDisplayMode {
        quotaChartDisplayPreferences.mode(for: model)
    }

    func setQuotaChartDisplayMode(
        _ mode: QuotaChartDisplayMode,
        model: ModelUsageData
    ) {
        var preferences = quotaChartDisplayPreferences
        preferences.setMode(mode, for: model)
        quotaChartDisplayPreferences = preferences
    }

    /// User-visible refreshes run at least one complete compact-icon self-test
    /// cycle and continue until the request completes. Background timer refreshes opt out.
    func refresh(showIconSelfTest: Bool = true) async {
        guard !isLoading else {
            return
        }

        let selfTestStartedAt = showIconSelfTest
            ? ProcessInfo.processInfo.systemUptime
            : nil
        if showIconSelfTest {
            isMenuBarSelfTesting = true
        }

        isLoading = true
        defer {
            isLoading = false
            isMenuBarSelfTesting = false
            updateStatusBarText()
            scheduleCycleEndRefresh()
        }
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
            await waitForMenuBarSelfTestCycle(startedAt: selfTestStartedAt)
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
        await waitForMenuBarSelfTestCycle(startedAt: selfTestStartedAt)
    }

    private func waitForMenuBarSelfTestCycle(startedAt: TimeInterval?) async {
        guard let startedAt else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        let remaining = MenuBarSelfTestFrame.cycleDuration - elapsed
        guard remaining > 0 else { return }

        do {
            try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        } catch {
            // Cancellation should restore the real icon immediately.
        }
    }

    private func shouldFetchProvider(_ provider: UsageProvider) -> Bool {
        switch provider {
        case .codex:
            return CodexAppPresence.isRunning
        case .miniMax:
            return true
        case .glm:
            return false
        case .kimi:
            return true
        }
    }

    func startAutoRefresh() {
        invalidateCycleEndTimer()
        restartTimer()

        if autoRefreshOnLaunch || usageData == nil {
            Task { @MainActor in
                // Let applicationDidFinishLaunching return before any
                // Keychain-backed provider discovery can request UI.
                try? await Task.sleep(nanoseconds: 500_000_000)
                await refresh(showIconSelfTest: true)
            }
        }
    }

    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
        invalidateCycleEndTimer()
    }

    func setMobileDashboardSelectedModelKeys(
        _ keys: [MobileDashboardModelSelectionKey]
    ) {
        let nextSelection = Set(
            keys.prefix(
                MobileDashboardService.maximumSelectedModelCount))
        guard nextSelection != mobileDashboardSelectedModelKeys else {
            return
        }
        mobileDashboardSelectedModelKeys = nextSelection
        if let usageData {
            recordSamples(
                from: usageData,
                timestamp: lastRefreshTime ?? usageData.timestamp)
        }
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
        let displayedProviderUsageData = Dictionary(
            uniqueKeysWithValues: providerUsageSections.map { ($0.provider, $0) }
        )
        return DataReportSnapshot(
            generatedAt: Date(),
            usageData: usageData,
            providerUsageData: displayedProviderUsageData,
            modelQuotaSamples: modelQuotaSamples,
            utilizationHistories: utilizationHistories
        )
    }

    func clearCloudUsageData() {
        cloudProviderUsageData = [:]
    }

    func clearCloudUsageData(for accountName: String) {
        let normalizedAccountName = Self.normalizedAccountName(accountName)
        guard !normalizedAccountName.isEmpty else { return }

        cloudProviderUsageData = cloudProviderUsageData.compactMapValues { data in
            let models = data.models.filter { model in
                model.normalizedAccountName != normalizedAccountName
            }
            return models.isEmpty ? nil : data.withModels(models)
        }

        guard !hasLocalAccount(named: normalizedAccountName) else { return }

        modelQuotaSamples = modelQuotaSamples.filter { modelID, _ in
            Self.normalizedAccountName(Self.accountName(fromModelID: modelID)) != normalizedAccountName
        }
        quotaSampleStore.saveAll(modelQuotaSamples)

        for provider in UsageProvider.allCases {
            guard var store = utilizationHistories[provider] else { continue }
            let histories = store.historiesOrEmpty.filter { modelID, _ in
                Self.normalizedAccountName(Self.accountName(fromModelID: modelID)) != normalizedAccountName
            }
            guard histories.count != store.historiesOrEmpty.count else { continue }
            store.histories = histories
            utilizationHistories[provider] = store
            utilizationStore.save(store, for: provider)
        }
    }

    func reloadCloudUsageData() async {
        await refreshCloudUsageData()
    }

    func loadedCloudRemoteAccountSummaries() -> [CloudRemoteAccountSummary] {
        let explicitCloudModels = cloudProviderUsageData.values
            .flatMap(\.models)
        let displayedCloudModels = providerUsageSections
            .flatMap(\.models)
            .filter { model in
                let source = model.parsedDetail.source
                return source == "Cloud" || source == "Mix"
            }
        let cloudModels = (explicitCloudModels + displayedCloudModels).filter { model in
            let accountName = (model.accountName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !accountName.isEmpty
        }
        let grouped = Dictionary(grouping: cloudModels) { model in
            [
                model.provider.rawValue,
                model.normalizedAccountName,
            ].joined(separator: ":")
        }

        return grouped.values.compactMap { models in
            guard let first = models.first,
                  let accountName = first.accountName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !accountName.isEmpty else {
                return nil
            }
            let latestSampledAt = models.compactMap(\.sampledAt).max()
                ?? cloudProviderUsageData[first.provider]?.timestamp
                ?? .distantPast
            let modelCount = Set(models.map(\.quotaIdentityKey)).count
            return CloudRemoteAccountSummary(
                provider: first.provider,
                accountName: accountName,
                latestSampledAt: latestSampledAt,
                sampleCount: models.count,
                modelCount: modelCount
            )
        }
        .sorted { lhs, rhs in
            if lhs.provider.rawValue != rhs.provider.rawValue {
                return lhs.provider.rawValue < rhs.provider.rawValue
            }
            if lhs.latestSampledAt != rhs.latestSampledAt {
                return lhs.latestSampledAt > rhs.latestSampledAt
            }
            return lhs.accountName.localizedStandardCompare(rhs.accountName) == .orderedAscending
        }
    }

    func clearLocalUsageData() {
        usageData = nil
        providerUsageData = [:]
        providerErrors = [:]
        error = nil
        lastRefreshTime = nil
        modelQuotaSamples = [:]
        cloudModelQuotaSamples = [:]
        utilizationHistories = [:]
        quotaSampleStore.clearAll()
        utilizationStore.clearAll()
        CloudSyncService.shared.clearPendingQueue()
        updateStatusBarText()
    }

    /// 云端同步状态：proxy 自 `CloudSyncService.shared.lastSyncStatus`。
    /// 设置面板的 `CloudSyncStatusLine` 实时显示"上次同步 Xm ago" / "失败 Ym ago"。
    var cloudSyncStatus: CloudSyncStatus {
        CloudSyncService.shared.lastSyncStatus
    }

    func samples(for model: ModelUsageData) -> [ModelQuotaSample] {
        guard let startTime = model.startTime,
              let endTime = model.endTime else {
            return []
        }
        return samples(for: model, in: (start: startTime, end: endTime))
    }

    /// 任意窗口的曲线样本：当前周期图表与历史 cycle 悬停预览共用。
    /// 历史窗口样本来自本地 90 天缓存（release）；DEBUG 用合成数据近似。
    func samples(for model: ModelUsageData, in window: (start: Date, end: Date)) -> [ModelQuotaSample] {
#if DEBUG
        return syntheticChartSamples(for: model, startTime: window.start, endTime: window.end)
#else
        let localSamples = modelQuotaSamples[model.id] ?? []
        let remoteSamples = cloudModelQuotaSamples[model.id] ?? []
        return Self.mergedQuotaSamples(localSamples, remoteSamples)
            .filter { $0.timestamp >= window.start && $0.timestamp <= window.end }
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
        let historicalCycles = history?.cycles(limit: limit, now: now, mode: utilizationHistoryMode) ?? []
        return ModelUtilizationCycleMerger.mergeLiveCurrentCycle(
            historicalCycles,
            model: model,
            limit: limit,
            now: now,
            mode: utilizationHistoryMode
        )
    }

    // MARK: - Private Methods

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(refreshInterval), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh(showIconSelfTest: false)
            }
        }
    }

    /// 每次刷新完成后调用：按本地已取回数据中最早的未来周期结束时间，
    /// 调度一次性定时器在结束 `cycleEndRefreshDelay` 秒后刷新，并让
    /// 10 分钟重复定时器从该时刻重新对齐。云端同步模型不参与。
    private func scheduleCycleEndRefresh(now: Date = Date()) {
        let fetchableProviders = Set(configuredProviders.filter(shouldFetchProvider))
        guard let endTime = nextCycleEndDate(at: now, fetchableProviders: fetchableProviders) else {
            invalidateCycleEndTimer()
            return
        }
        let fireDate = endTime.addingTimeInterval(cycleEndRefreshDelay)
        guard fireDate != cycleEndFireDate else { return }
        invalidateCycleEndTimer()
        let timer = Timer.scheduledTimer(
            withTimeInterval: fireDate.timeIntervalSince(now),
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                invalidateCycleEndTimer()
                await refresh(showIconSelfTest: false)
                restartTimer()
            }
        }
        timer.tolerance = 5
        cycleEndFireDate = fireDate
        cycleEndTimer = timer
    }

    /// 本地已取回数据中最早的未来周期结束时间（5h `endTime` 与周
    /// `weeklyEndTime`），跳过已过去的结束时间；只统计会被实际 fetch 的 provider。
    func nextCycleEndDate(
        at now: Date,
        fetchableProviders: Set<UsageProvider>
    ) -> Date? {
        providerUsageData.values
            .filter { fetchableProviders.contains($0.provider) }
            .flatMap(\.models)
            .flatMap { [$0.endTime, $0.weeklyEndTime].compactMap { $0 } }
            .filter { $0 > now }
            .min()
    }

    private func invalidateCycleEndTimer() {
        cycleEndTimer?.invalidate()
        cycleEndTimer = nil
        cycleEndFireDate = nil
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

    private func hasLocalAccount(named normalizedAccountName: String) -> Bool {
        providerUsageData.values
            .flatMap(\.models)
            .contains { model in
                model.normalizedAccountName == normalizedAccountName
            }
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

    private static func accountName(fromModelID id: String) -> String {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return "" }
        return parts[1]
    }

    private static func normalizedAccountName(_ accountName: String) -> String {
        accountName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
            cloudModelQuotaSamples = [:]
        }
    }

    private func refreshCloudUsageData() async {
        guard cloudSyncEnabled else {
            cloudProviderUsageData = [:]
            return
        }

        do {
            cloudProviderUsageData = try await CloudSyncService.shared.fetchRemoteUsageData()
            do {
                cloudModelQuotaSamples = try await CloudSyncService.shared.fetchRemoteModelQuotaSamples()
            } catch {
                // 瞬时失败保留上次样本，避免面板曲线图闪空。
                cloudUsageLoadError = error.localizedDescription
                return
            }
            cloudUsageLoadError = nil
        } catch {
            // Cloud rows are supplemental. Keep local quota usable if remote history cannot load.
            cloudProviderUsageData = [:]
            // 保留上次 cloudModelQuotaSamples，避免瞬时失败导致曲线图闪空。
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
    private static let combinedProviderPriority: [UsageProvider] = [.codex, .kimi, .miniMax]

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
        // 从现有样本合并：本次刷新缺失的 model 保留历史，
        // 历史周期样本也保留（悬停 cycle 预览曲线依赖它们）。
        var nextSamples = modelQuotaSamples
        let renderableModelIDs = Set(data.models
            .filter { $0.containsCurrentInterval(at: timestamp) }
            .map(\.id))
        let curveModelIDs = QuotaCurveModelSelector.curveModelIDs(
            in: data.models,
            renderableModelIDs: renderableModelIDs,
            preferences: quotaChartDisplayPreferences)
        let sampledModelIDs = Self.sampledModelIDs(
            curveModelIDs: curveModelIDs,
            models: data.models,
            mobileSelectionKeys:
                mobileDashboardSelectedModelKeys)

        for model in data.models where sampledModelIDs.contains(model.id) {
            guard let startTime = model.startTime,
                  let endTime = model.endTime else {
                continue
            }

            let clampedTimestamp = min(max(timestamp, startTime), endTime)
            let newSample = ModelQuotaSample(
                timestamp: clampedTimestamp,
                remaining: model.currentIntervalRemaining,
                percent: model.currentIntervalRemainingPercent
            )

            var samples = (nextSamples[model.id] ?? [])
                .sorted { $0.timestamp < $1.timestamp }

            if let lastSample = samples.last,
               abs(lastSample.timestamp.timeIntervalSince1970 - newSample.timestamp.timeIntervalSince1970) < 1 {
                samples[samples.count - 1] = newSample
            } else {
                samples.append(newSample)
            }

            nextSamples[model.id] = Self.prunedQuotaSamples(samples, now: timestamp)
        }

        // 历史 model 也统一裁剪，避免不再上报的 model 永久占用磁盘
        for (modelID, samples) in nextSamples where !sampledModelIDs.contains(modelID) {
            nextSamples[modelID] = Self.prunedQuotaSamples(samples, now: timestamp)
        }

        modelQuotaSamples = nextSamples
        quotaSampleStore.saveAll(modelQuotaSamples)
    }

    /// 曲线样本本地保留策略：按年龄保留 `quotaSampleRetention`（90 天），
    /// 并按 `maxSamplesPerModel` 封顶，超出丢最旧。
    /// 默认 10 分钟刷新 ≈ 13k 样本/90 天，不会触顶。
    nonisolated static let quotaSampleRetention: TimeInterval = 90 * 86_400
    nonisolated static let maxSamplesPerModel = 30_000

    nonisolated static func prunedQuotaSamples(
        _ samples: [ModelQuotaSample],
        now: Date
    ) -> [ModelQuotaSample] {
        let cutoff = now.addingTimeInterval(-quotaSampleRetention)
        var result = samples
            .filter { $0.timestamp >= cutoff }
            .sorted { $0.timestamp < $1.timestamp }
        if result.count > maxSamplesPerModel {
            result.removeFirst(result.count - maxSamplesPerModel)
        }
        return result
    }

    nonisolated static func sampledModelIDs(
        curveModelIDs: Set<String>,
        models: [ModelUsageData],
        mobileSelectionKeys:
            Set<MobileDashboardModelSelectionKey>
    ) -> Set<String> {
        var result = curveModelIDs
        result.formUnion(
            models.lazy.filter {
                mobileSelectionKeys.contains(
                    $0.mobileDashboardSelectionKey)
            }.map(\.id))
        return result
    }

    private static func mergedQuotaSamples(_ lhs: [ModelQuotaSample], _ rhs: [ModelQuotaSample]) -> [ModelQuotaSample] {
        var byTimestamp = Dictionary(uniqueKeysWithValues: lhs.map { ($0.id, $0) })
        for sample in rhs {
            byTimestamp[sample.id] = sample
        }
        return byTimestamp.values.sorted { $0.timestamp < $1.timestamp }
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
    /// Generates deterministic debug chart points while capping long Weekly
    /// windows to roughly 240 samples so preview rendering stays lightweight.
    private func syntheticChartSamples(
        for model: ModelUsageData,
        startTime: Date,
        endTime: Date
    ) -> [ModelQuotaSample] {
        let clampedNow = min(max(Date(), startTime), endTime)
        let elapsed = max(clampedNow.timeIntervalSince(startTime), 0)
        let sampleInterval = max(60, elapsed / 240)
        let sampleCount = Int(elapsed / sampleInterval)
        let base = startTime.timeIntervalSince1970
        let endPercent = model.currentIntervalRemainingPercent

        var samples: [ModelQuotaSample] = (0 ... sampleCount).map { index in
            let ratio = sampleCount > 0 ? Double(index) / Double(sampleCount) : 0
            let timestamp = Date(
                timeIntervalSince1970: base + Double(index) * sampleInterval)
            if let endPercent {
                let interpolated = 100 + Double(endPercent - 100) * ratio
                return ModelQuotaSample(
                    timestamp: timestamp,
                    remaining: Int(interpolated.rounded()),
                    percent: Int(interpolated.rounded()))
            }

            let startRemaining = model.currentIntervalTotal > 0
                ? min(4500, model.currentIntervalTotal)
                : 4500
            let endRemaining = max(
                0,
                min(model.currentIntervalRemaining, startRemaining))
            let interpolated = Double(startRemaining)
                + Double(endRemaining - startRemaining) * ratio
            return ModelQuotaSample(
                timestamp: timestamp,
                remaining: Int(interpolated.rounded()))
        }

        let lastSample = ModelQuotaSample(
            timestamp: clampedNow,
            remaining: endPercent ?? model.currentIntervalRemaining,
            percent: endPercent)
        if samples.last?.timestamp != clampedNow {
            samples.append(lastSample)
        } else if !samples.isEmpty {
            samples[samples.count - 1] = lastSample
        }

        return samples
    }
#endif
}
