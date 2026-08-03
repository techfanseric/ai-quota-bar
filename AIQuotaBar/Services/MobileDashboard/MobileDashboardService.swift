import Foundation
import Network
import Security
import SystemConfiguration

enum MobileDashboardServiceState: Equatable {
    case off
    case starting
    case ready
    case failed(String)
}

enum MobileDashboardActivityBackgroundEffect: String, Codable, CaseIterable,
    Identifiable
{
    case grainyDigitalRain
    case dotWaves
    case taskTelemetryMarquee

    var id: String { rawValue }
}

enum MobileDashboardTaskTelemetryField: String, Codable, CaseIterable,
    Identifiable, Hashable
{
    case title
    case state
    case phase
    case project
    case gitBranch
    case source
    case model
    case modelProvider
    case reasoningEffort
    case sandboxPolicy
    case approvalMode
    case tokensUsed
    case activeSubtasks
    case subtaskNames
    case createdAt
    case startedAt
    case elapsed
    case lastUpdated
    case cliVersion
    case tool
    case recentEvent
    case progress

    var id: String { rawValue }
}

@MainActor
@Observable
final class MobileDashboardService {
    static let defaultPort: UInt16 = 18_765
    static let liveUpdateOwner = "mobile-dashboard"
    static let manualPairingCodeLifetime: TimeInterval = 5 * 60
    nonisolated static let selectedModelsDefaultsKey =
        "mobileDashboardSelectedModels"
    nonisolated static let maximumSelectedModelCount = 2

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: DefaultsKey.enabled)
            if isEnabled {
                start()
            } else {
                stop()
            }
        }
    }

    var masksAccountNames: Bool {
        didSet {
            defaults.set(
                masksAccountNames,
                forKey: DefaultsKey.masksAccountNames)
            lastBroadcastSnapshot = nil
        }
    }

    /// Allows the phone to replace a confirmed-idle dashboard with the
    /// full-screen black marquee. It never changes the underlying activity
    /// state, so stale, unavailable, and offline remain distinguishable.
    var idleBlackoutMarqueeEnabled: Bool {
        didSet {
            defaults.set(
                idleBlackoutMarqueeEnabled,
                forKey: DefaultsKey.idleBlackoutMarqueeEnabled)
            lastBroadcastIdleBlackoutMarqueeEnabled = nil
        }
    }

    var oledProtectionEnabled: Bool {
        didSet {
            defaults.set(
                oledProtectionEnabled,
                forKey: DefaultsKey.oledProtectionEnabled)
            lastBroadcastSnapshot = nil
        }
    }

    var experimentalWakeMediaEnabled: Bool {
        didSet {
            defaults.set(
                experimentalWakeMediaEnabled,
                forKey: DefaultsKey.experimentalWakeMediaEnabled)
            lastBroadcastSnapshot = nil
        }
    }

    /// Controls only the decorative background of the Codex Activity card.
    /// It does not alter task telemetry or any other dashboard section.
    var activityBackgroundEffect: MobileDashboardActivityBackgroundEffect {
        didSet {
            defaults.set(
                activityBackgroundEffect.rawValue,
                forKey: DefaultsKey.activityBackgroundEffect)
            lastBroadcastActivityBackgroundEffect = nil
        }
    }

    var taskTelemetryFields: Set<MobileDashboardTaskTelemetryField> {
        didSet {
            defaults.set(
                MobileDashboardTaskTelemetryField.allCases
                    .filter(taskTelemetryFields.contains)
                    .map(\.rawValue),
                forKey: DefaultsKey.taskTelemetryFields)
            lastBroadcastTaskTelemetryFields = nil
        }
    }

    var colorScheme: MobileDashboardColorScheme {
        didSet {
            defaults.set(
                colorScheme.rawValue,
                forKey: DefaultsKey.colorScheme)
            if isRunningRequested {
                server.updateColorScheme(colorScheme)
            }
            lastBroadcastColorScheme = nil
        }
    }

    private(set) var requiresPairingCode: Bool
    /// Opt-in because sanitized task titles, project names, and assistant
    /// commentary may reveal task intent. It is forcibly disabled whenever
    /// manual pairing is disabled.
    var shareTaskProgressText: Bool {
        didSet {
            let effective = shareTaskProgressText && requiresPairingCode
            if shareTaskProgressText != effective {
                // Assigning inside this observer replaces the value without
                // recursively invoking the observer.
                shareTaskProgressText = effective
            }
            defaults.set(effective, forKey: DefaultsKey.shareTaskProgressText)
            if effective != oldValue {
                lastBroadcastSnapshot = nil
            }
        }
    }

    private(set) var selectedModelKeys:
        [MobileDashboardModelSelectionKey]

    private(set) var state: MobileDashboardServiceState = .off
    private(set) var viewerCount = 0
    private(set) var accessURLString: String?
    private(set) var alternateURLStrings: [String] = []
    private(set) var lastRouteTestedAt: Date?
    private(set) var manualPairingCode: String?
    private(set) var manualPairingCodeExpiresAt: Date?

    private enum DefaultsKey {
        static let enabled = "mobileDashboardEnabled"
        static let masksAccountNames =
            "mobileDashboardMasksAccountNames"
        static let idleBlackoutMarqueeEnabled =
            "mobileDashboardIdleBlackoutMarqueeEnabled"
        static let oledProtectionEnabled =
            "mobileDashboardOLEDProtectionEnabled"
        static let experimentalWakeMediaEnabled =
            "mobileDashboardExperimentalWakeMediaEnabled"
        static let activityBackgroundEffect =
            "mobileDashboardActivityBackgroundEffect"
        static let taskTelemetryFields =
            "mobileDashboardTaskTelemetryFields"
        static let colorScheme =
            "mobileDashboardColorScheme"
        static let requiresPairingCode =
            "mobileDashboardRequiresPairingCode"
        static let shareTaskProgressText =
            "mobileDashboardShareTaskProgressText"
        static let selectedModels =
            MobileDashboardService.selectedModelsDefaultsKey
    }

    private let defaults: UserDefaults
    private let accessTokenStore:
        any MobileDashboardAccessTokenStoring
    @ObservationIgnored private let startupAccessTokenExecutor:
        MobileDashboardAccessTokenExecutor
    private let snapshotProvider:
        @MainActor (
            Bool,
            Date?,
            [MobileDashboardModelSelectionKey],
            Bool
        ) -> MobileDashboardSnapshot
    private let onViewerActivityChanged: @MainActor (Bool) -> Void
    private let refreshRoute: @MainActor () async -> Void
    private let testRoutes: @MainActor () async -> Void
    @ObservationIgnored private lazy var server =
        MobileDashboardHTTPServer(
        stateHandler: { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleServerState(state)
            }
        },
        viewerCountHandler: { [weak self] count in
            Task { @MainActor [weak self] in
                self?.handleViewerCount(count)
            }
        })
    @ObservationIgnored private var accessToken = ""
    @ObservationIgnored private var broadcastTask: Task<Void, Never>?
    @ObservationIgnored private var routeTask: Task<Void, Never>?
    @ObservationIgnored private var viewerGraceTask: Task<Void, Never>?
    @ObservationIgnored private var networkMonitor: NWPathMonitor?
    @ObservationIgnored private var localHostNameMonitor:
        MobileDashboardLocalHostNameMonitor?
    @ObservationIgnored private var isRunningRequested = false
    @ObservationIgnored private var lastBroadcastSnapshot:
        MobileDashboardSnapshot?
    @ObservationIgnored private var
        lastBroadcastOLEDProtectionEnabled: Bool?
    @ObservationIgnored private var
        lastBroadcastExperimentalWakeMediaEnabled: Bool?
    @ObservationIgnored private var lastBroadcastActivityBackgroundEffect:
        MobileDashboardActivityBackgroundEffect?
    @ObservationIgnored private var lastBroadcastTaskTelemetryFields:
        [MobileDashboardTaskTelemetryField]?
    @ObservationIgnored private var lastBroadcastColorScheme:
        MobileDashboardColorScheme?
    @ObservationIgnored private var
        lastBroadcastIdleBlackoutMarqueeEnabled: Bool?
    @ObservationIgnored private var lastHeartbeatAt = Date.distantPast
    @ObservationIgnored private var hasPersistedModelSelection: Bool
    @ObservationIgnored private var tokenStartupTask:
        Task<Void, Never>?
    @ObservationIgnored private var startupGeneration: UInt64 = 0
    @ObservationIgnored private var lastManualPairingCode: String?

    init(
        defaults: UserDefaults = .standard,
        accessTokenStore:
            any MobileDashboardAccessTokenStoring =
                MobileDashboardKeychainTokenStore(),
        snapshotProvider:
            @escaping @MainActor (
                Bool,
                Date?,
                [MobileDashboardModelSelectionKey],
                Bool
            )
                -> MobileDashboardSnapshot,
        onViewerActivityChanged:
            @escaping @MainActor (Bool) -> Void,
        refreshRoute: @escaping @MainActor () async -> Void,
        testRoutes: @escaping @MainActor () async -> Void
    ) {
        self.defaults = defaults
        self.accessTokenStore = accessTokenStore
        startupAccessTokenExecutor =
            MobileDashboardAccessTokenExecutor(
                store: accessTokenStore)
        self.snapshotProvider = snapshotProvider
        self.onViewerActivityChanged = onViewerActivityChanged
        self.refreshRoute = refreshRoute
        self.testRoutes = testRoutes
        let storedSelection = Self.loadModelSelection(
            defaults: defaults)
        selectedModelKeys = storedSelection ?? []
        hasPersistedModelSelection = storedSelection != nil
        isEnabled = defaults.bool(forKey: DefaultsKey.enabled)
        // Deliberately do not migrate the inverse legacy "show full names"
        // preference. A missing new key is an upgrade boundary and returns to
        // the safer masked default.
        masksAccountNames = defaults.object(
            forKey: DefaultsKey.masksAccountNames
        ) as? Bool ?? true
        idleBlackoutMarqueeEnabled = defaults.object(
            forKey: DefaultsKey.idleBlackoutMarqueeEnabled
        ) as? Bool ?? true
        oledProtectionEnabled =
            defaults.object(
                forKey: DefaultsKey.oledProtectionEnabled
            ) as? Bool ?? true
        experimentalWakeMediaEnabled =
            defaults.object(
                forKey: DefaultsKey.experimentalWakeMediaEnabled
            ) as? Bool ?? false
        activityBackgroundEffect =
            MobileDashboardActivityBackgroundEffect(
                rawValue: defaults.string(
                    forKey: DefaultsKey.activityBackgroundEffect) ?? ""
            ) ?? .grainyDigitalRain
        if let storedTaskTelemetryFields = defaults.array(
            forKey: DefaultsKey.taskTelemetryFields
        ) as? [String] {
            taskTelemetryFields = Set(
                storedTaskTelemetryFields.compactMap(
                    MobileDashboardTaskTelemetryField.init(rawValue:)))
        } else {
            taskTelemetryFields = Set(
                MobileDashboardTaskTelemetryField.allCases)
        }
        colorScheme = MobileDashboardColorScheme(
            rawValue: defaults.string(
                forKey: DefaultsKey.colorScheme) ?? ""
        ) ?? .automatic
        // This is intentionally opt-in for both fresh and upgraded installs.
        // An existing installation has no value for this newly introduced
        // key, so it adopts the requested pairing-free default as well.
        let storedRequiresPairingCode = defaults.object(
            forKey: DefaultsKey.requiresPairingCode
        ) as? Bool ?? false
        let storedShareTaskProgressText = defaults.object(
            forKey: DefaultsKey.shareTaskProgressText
        ) as? Bool ?? false
        requiresPairingCode = storedRequiresPairingCode
        shareTaskProgressText = storedRequiresPairingCode
            && storedShareTaskProgressText
        if storedShareTaskProgressText && !storedRequiresPairingCode {
            defaults.set(false, forKey: DefaultsKey.shareTaskProgressText)
        }
    }

    /// Initializes the default selection once model candidates become
    /// available. Existing selections, including temporarily unavailable
    /// models, are retained unchanged.
    func initializeModelSelectionIfNeeded(
        candidates: [ModelUsageData]
    ) {
        guard !hasPersistedModelSelection else { return }
        let defaults = Self.defaultModelSelectionKeys(
            candidates: candidates)
        guard !defaults.isEmpty else { return }
        selectedModelKeys = Array(
            defaults.prefix(Self.maximumSelectedModelCount))
        persistModelSelection()
    }

    private static func defaultModelSelectionKeys(
        candidates: [ModelUsageData],
        now: Date = Date()
    ) -> [MobileDashboardModelSelectionKey] {
        var seen = Set<MobileDashboardModelSelectionKey>()
        let uniqueCandidates = candidates.filter {
            seen.insert($0.mobileDashboardSelectionKey).inserted
        }
        let renderableModelIDs = Set(
            uniqueCandidates.filter {
                $0.containsCurrentInterval(at: now)
            }.map(\.id))
        let curveModelIDs = QuotaCurveModelSelector.curveModelIDs(
            in: uniqueCandidates,
            renderableModelIDs: renderableModelIDs)
        let curveCandidates = uniqueCandidates.filter {
            curveModelIDs.contains($0.id)
        }
        let remainingCandidates = uniqueCandidates.filter {
            !curveModelIDs.contains($0.id)
        }
        return (curveCandidates + remainingCandidates)
            .map(\.mobileDashboardSelectionKey)
    }

    /// Replaces the selection while enforcing the mobile contract of at least
    /// one and at most two models.
    @discardableResult
    func setSelectedModelKeys(
        _ keys: [MobileDashboardModelSelectionKey]
    ) -> Bool {
        let supported = keys.filter(\.isSupported)
        let unique = Self.uniqueSelectionKeys(supported)
        guard !unique.isEmpty,
              unique.count <= Self.maximumSelectedModelCount else {
            return false
        }
        guard unique != selectedModelKeys
                || !hasPersistedModelSelection else {
            return true
        }
        selectedModelKeys = unique
        persistModelSelection()
        lastBroadcastSnapshot = nil
        return true
    }

    @discardableResult
    func toggleModelSelection(
        _ key: MobileDashboardModelSelectionKey
    ) -> Bool {
        guard key.isSupported else { return false }
        if let index = selectedModelKeys.firstIndex(of: key) {
            guard selectedModelKeys.count > 1 else { return false }
            var next = selectedModelKeys
            next.remove(at: index)
            return setSelectedModelKeys(next)
        }
        guard selectedModelKeys.count
                < Self.maximumSelectedModelCount else {
            return false
        }
        return setSelectedModelKeys(selectedModelKeys + [key])
    }

    func isModelSelected(_ model: ModelUsageData) -> Bool {
        selectedModelKeys.contains(
            model.mobileDashboardSelectionKey)
    }

    func isTaskTelemetryFieldEnabled(
        _ field: MobileDashboardTaskTelemetryField
    ) -> Bool {
        taskTelemetryFields.contains(field)
    }

    func setTaskTelemetryField(
        _ field: MobileDashboardTaskTelemetryField,
        enabled: Bool
    ) {
        var next = taskTelemetryFields
        if enabled {
            next.insert(field)
        } else {
            next.remove(field)
        }
        taskTelemetryFields = next
    }

    private var orderedTaskTelemetryFields:
        [MobileDashboardTaskTelemetryField]
    {
        MobileDashboardTaskTelemetryField.allCases.filter(
            taskTelemetryFields.contains)
    }

    func startIfEnabled() {
        guard isEnabled else {
            state = .off
            return
        }
        start()
    }

    func stopForApplicationTermination() {
        stop()
    }

    func regenerateAccessLink() -> Bool {
        guard let nextToken = Self.generateAccessToken(),
              accessTokenStore.saveMobileDashboardAccessToken(
                nextToken) else {
            state = .failed(
                localized(
                    english: "The access key could not be saved to Keychain.",
                    chinese: "访问密钥无法保存到钥匙串。"))
            return false
        }

        accessToken = nextToken
        lastBroadcastSnapshot = nil
        lastBroadcastOLEDProtectionEnabled = nil
        lastBroadcastExperimentalWakeMediaEnabled = nil
        lastBroadcastActivityBackgroundEffect = nil
        lastBroadcastTaskTelemetryFields = nil
        lastBroadcastColorScheme = nil
        lastBroadcastIdleBlackoutMarqueeEnabled = nil
        if isEnabled {
            startServer()
        } else {
            accessToken = ""
            accessURLString = nil
            alternateURLStrings = []
            manualPairingCode = nil
            manualPairingCodeExpiresAt = nil
        }
        return true
    }

    /// Changes how new devices obtain the read-only bearer token. Existing
    /// bearers deliberately remain valid; revoking them is an explicit access
    /// key reset operation, not a side effect of this preference.
    @discardableResult
    func setRequiresPairingCode(_ required: Bool) -> Bool {
        guard required != requiresPairingCode else { return true }

        let pairing: (code: String, expiresAt: Date)?
        if required, isEnabled, !accessToken.isEmpty {
            guard let code = freshManualPairingCode() else {
                return false
            }
            pairing = (
                code,
                Date().addingTimeInterval(
                    Self.manualPairingCodeLifetime))
        } else {
            pairing = nil
        }

        requiresPairingCode = required
        defaults.set(required, forKey: DefaultsKey.requiresPairingCode)
        if !required {
            shareTaskProgressText = false
            defaults.set(false, forKey: DefaultsKey.shareTaskProgressText)
            lastBroadcastSnapshot = nil
        }
        manualPairingCode = pairing?.code
        manualPairingCodeExpiresAt = pairing?.expiresAt
        if isEnabled, !accessToken.isEmpty {
            server.updatePairingPolicy(
                requiresPairingCode: required,
                manualPairingCode: pairing?.code,
                manualPairingCodeExpiresAt: pairing?.expiresAt)
        }
        return true
    }

    /// Changes the separately opt-in text-sharing policy. Pairing is a hard
    /// prerequisite; callers cannot accidentally persist an unsafe state.
    @discardableResult
    func setShareTaskProgressText(_ shared: Bool) -> Bool {
        guard !shared || requiresPairingCode else {
            if shareTaskProgressText {
                shareTaskProgressText = false
                defaults.set(false, forKey: DefaultsKey.shareTaskProgressText)
                lastBroadcastSnapshot = nil
            }
            return false
        }
        guard shared != shareTaskProgressText else { return true }
        shareTaskProgressText = shared
        defaults.set(shared, forKey: DefaultsKey.shareTaskProgressText)
        lastBroadcastSnapshot = nil
        return true
    }

    @discardableResult
    func refreshManualPairingCode() -> Bool {
        guard isEnabled,
              requiresPairingCode,
              !accessToken.isEmpty,
              let code = freshManualPairingCode() else {
            return false
        }
        let expiresAt = Date().addingTimeInterval(
            Self.manualPairingCodeLifetime)
        manualPairingCode = code
        manualPairingCodeExpiresAt = expiresAt
        server.updateManualPairingCode(
            code,
            expiresAt: expiresAt)
        return true
    }

    private func start() {
        guard isEnabled, !isRunningRequested else { return }
        isRunningRequested = true
        startWithToken()
    }

    private func startWithToken() {
        state = .starting
        viewerCount = 0
        startupGeneration &+= 1
        let generation = startupGeneration
        tokenStartupTask?.cancel()
        let startupAccessTokenExecutor =
            startupAccessTokenExecutor
        tokenStartupTask = Task { @MainActor [weak self] in
            let loadResult = await startupAccessTokenExecutor.load()
            guard !Task.isCancelled,
                  let self,
                  self.isCurrentStartup(generation) else {
                return
            }

            switch loadResult {
            case let .found(storedToken):
                self.finishTokenStartup(
                    token: storedToken,
                    generation: generation)
                return
            case .failure:
                self.failTokenStartup(generation: generation)
                return
            case .notFound:
                break
            }

            guard let generatedToken = Self.generateAccessToken()
            else {
                self.failTokenStartup(generation: generation)
                return
            }
            let saved = await startupAccessTokenExecutor.save(
                generatedToken)
            guard !Task.isCancelled,
                  self.isCurrentStartup(generation) else {
                return
            }
            guard saved else {
                self.failTokenStartup(generation: generation)
                return
            }
            self.finishTokenStartup(
                token: generatedToken,
                generation: generation)
        }
    }

    private func isCurrentStartup(_ generation: UInt64) -> Bool {
        isEnabled
            && isRunningRequested
            && startupGeneration == generation
    }

    private func finishTokenStartup(
        token: String,
        generation: UInt64
    ) {
        guard isCurrentStartup(generation) else { return }
        tokenStartupTask = nil
        accessToken = token
        startServer()
    }

    private func failTokenStartup(generation: UInt64) {
        guard isCurrentStartup(generation) else { return }
        tokenStartupTask = nil
        isRunningRequested = false
        state = .failed(
            localized(
                english:
                    "The access key could not be created in Keychain.",
                chinese: "无法在钥匙串中创建访问密钥。"))
    }

    private func startServer() {
        guard !accessToken.isEmpty else { return }
        let pairing: (code: String, expiresAt: Date)?
        if requiresPairingCode {
            guard let code = freshManualPairingCode() else {
                state = .failed(
                    localized(
                        english: "A secure manual pairing code could not be created.",
                        chinese: "无法生成安全的手动配对码。"))
                return
            }
            pairing = (
                code,
                Date().addingTimeInterval(
                    Self.manualPairingCodeLifetime))
        } else {
            pairing = nil
        }
        manualPairingCode = pairing?.code
        manualPairingCodeExpiresAt = pairing?.expiresAt
        state = .starting
        startNetworkMonitoring()
        updateAccessURLs()
        server.start(
            port: Self.defaultPort,
            accessToken: accessToken,
            colorScheme: colorScheme,
            requiresPairingCode: requiresPairingCode,
            manualPairingCode: pairing?.code,
            manualPairingCodeExpiresAt: pairing?.expiresAt)
    }

    private func stop() {
        isRunningRequested = false
        startupGeneration &+= 1
        tokenStartupTask?.cancel()
        tokenStartupTask = nil
        broadcastTask?.cancel()
        broadcastTask = nil
        routeTask?.cancel()
        routeTask = nil
        viewerGraceTask?.cancel()
        viewerGraceTask = nil
        onViewerActivityChanged(false)
        networkMonitor?.cancel()
        networkMonitor = nil
        localHostNameMonitor?.stop()
        localHostNameMonitor = nil
        server.stop()
        viewerCount = 0
        accessURLString = nil
        alternateURLStrings = []
        manualPairingCode = nil
        manualPairingCodeExpiresAt = nil
        accessToken = ""
        lastBroadcastSnapshot = nil
        lastBroadcastOLEDProtectionEnabled = nil
        lastBroadcastExperimentalWakeMediaEnabled = nil
        lastBroadcastActivityBackgroundEffect = nil
        lastBroadcastTaskTelemetryFields = nil
        lastBroadcastColorScheme = nil
        lastBroadcastIdleBlackoutMarqueeEnabled = nil
        lastHeartbeatAt = .distantPast
        state = .off
    }

    private func handleServerState(
        _ serverState: MobileDashboardHTTPServer.State
    ) {
        guard isEnabled, isRunningRequested else { return }
        switch serverState {
        case .stopped:
            if state != .off {
                state = .starting
            }
        case .starting:
            state = .starting
        case .ready:
            state = .ready
            updateAccessURLs()
        case let .failed(message):
            networkMonitor?.cancel()
            networkMonitor = nil
            localHostNameMonitor?.stop()
            localHostNameMonitor = nil
            state = .failed(
                localized(
                    english:
                        "The mobile dashboard could not start. \(message)",
                    chinese:
                        "手机看板无法启动。\(message)"))
        }
    }

    private func handleViewerCount(_ count: Int) {
        guard isEnabled else { return }
        let previousCount = viewerCount
        viewerCount = count
        if count > 0 {
            if MobileDashboardViewerBroadcastPolicy
                .shouldInvalidateSnapshot(
                    previousCount: previousCount,
                    newCount: count) {
                lastBroadcastSnapshot = nil
                lastBroadcastOLEDProtectionEnabled = nil
                lastBroadcastExperimentalWakeMediaEnabled = nil
                lastBroadcastActivityBackgroundEffect = nil
                lastBroadcastTaskTelemetryFields = nil
                lastBroadcastColorScheme = nil
                lastBroadcastIdleBlackoutMarqueeEnabled = nil
            }
            viewerGraceTask?.cancel()
            viewerGraceTask = nil
            activateViewerMode()
        } else {
            scheduleViewerModeDeactivation()
        }
    }

    private func activateViewerMode() {
        onViewerActivityChanged(true)
        if broadcastTask == nil {
            broadcastTask = Task { @MainActor [weak self] in
                await self?.runBroadcastLoop()
            }
        }
        if routeTask == nil {
            routeTask = Task { @MainActor [weak self] in
                await self?.runRouteLoop()
            }
        }
    }

    private func scheduleViewerModeDeactivation() {
        guard viewerGraceTask == nil else { return }
        viewerGraceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }
            guard let self, self.viewerCount == 0 else { return }
            self.broadcastTask?.cancel()
            self.broadcastTask = nil
            self.routeTask?.cancel()
            self.routeTask = nil
            self.lastBroadcastSnapshot = nil
            self.lastBroadcastOLEDProtectionEnabled = nil
            self.lastBroadcastExperimentalWakeMediaEnabled = nil
            self.lastBroadcastActivityBackgroundEffect = nil
            self.lastBroadcastTaskTelemetryFields = nil
            self.lastBroadcastColorScheme = nil
            self.lastBroadcastIdleBlackoutMarqueeEnabled = nil
            self.onViewerActivityChanged(false)
            self.viewerGraceTask = nil
        }
    }

    private func runBroadcastLoop() async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        while !Task.isCancelled, isEnabled {
            if viewerCount > 0 {
                do {
                    let snapshot = snapshotProvider(
                        masksAccountNames,
                        lastRouteTestedAt,
                        selectedModelKeys,
                        shareTaskProgressText && requiresPairingCode)
                    let shouldBroadcast =
                        lastBroadcastSnapshot == nil
                        || !(lastBroadcastSnapshot?
                            .hasSameContent(as: snapshot) ?? false)
                        || lastBroadcastOLEDProtectionEnabled
                            != oledProtectionEnabled
                        || lastBroadcastExperimentalWakeMediaEnabled
                            != experimentalWakeMediaEnabled
                        || lastBroadcastActivityBackgroundEffect
                            != activityBackgroundEffect
                        || lastBroadcastTaskTelemetryFields
                            != orderedTaskTelemetryFields
                        || lastBroadcastColorScheme != colorScheme
                        || lastBroadcastIdleBlackoutMarqueeEnabled
                            != idleBlackoutMarqueeEnabled
                    guard shouldBroadcast else {
                        if Date().timeIntervalSince(
                            lastHeartbeatAt) >= 20 {
                            server.sendHeartbeat()
                            lastHeartbeatAt = Date()
                        }
                        try await Task.sleep(for: .seconds(1))
                        continue
                    }
                    let envelope = MobileDashboardEventEnvelope(
                        oledProtectionEnabled: oledProtectionEnabled,
                        experimentalWakeMediaEnabled:
                            experimentalWakeMediaEnabled,
                        activityBackgroundEffect:
                            activityBackgroundEffect,
                        taskTelemetryFields:
                            orderedTaskTelemetryFields,
                        colorScheme: colorScheme,
                        idleBlackoutMarqueeEnabled:
                            idleBlackoutMarqueeEnabled,
                        snapshot: snapshot)
                    let data = try encoder.encode(envelope)
                    server.broadcast(snapshotData: data)
                    lastBroadcastSnapshot = snapshot
                    lastBroadcastOLEDProtectionEnabled =
                        oledProtectionEnabled
                    lastBroadcastExperimentalWakeMediaEnabled =
                        experimentalWakeMediaEnabled
                    lastBroadcastActivityBackgroundEffect =
                        activityBackgroundEffect
                    lastBroadcastTaskTelemetryFields =
                        orderedTaskTelemetryFields
                    lastBroadcastColorScheme = colorScheme
                    lastBroadcastIdleBlackoutMarqueeEnabled =
                        idleBlackoutMarqueeEnabled
                    lastHeartbeatAt = Date()
                } catch {
                    // A later state change will retry encoding.
                }
            }

            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
    }

    private func runRouteLoop() async {
        await refreshRoute()
        guard !Task.isCancelled else { return }
        if shouldTestRoutes {
            await testRoutes()
            guard !Task.isCancelled else { return }
            lastRouteTestedAt = Date()
        }

        while !Task.isCancelled, isEnabled {
            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }
            guard viewerCount > 0 else { continue }
            await refreshRoute()
            guard !Task.isCancelled else { return }
            if shouldTestRoutes {
                await testRoutes()
                guard !Task.isCancelled else { return }
                lastRouteTestedAt = Date()
            }
        }
    }

    private var shouldTestRoutes: Bool {
        guard let lastRouteTestedAt else { return true }
        return Date().timeIntervalSince(lastRouteTestedAt) >= 5 * 60
    }

    private func startNetworkMonitoring() {
        if networkMonitor == nil {
            let monitor = NWPathMonitor()
            networkMonitor = monitor
            monitor.pathUpdateHandler = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateAccessURLs()
                }
            }
            monitor.start(
                queue: DispatchQueue(
                    label:
                        "com.techfanseric.aiquotabar.mobile-dashboard.path"))
        }

        if localHostNameMonitor == nil {
            let monitor = MobileDashboardLocalHostNameMonitor {
                [weak self] in
                Task { @MainActor [weak self] in
                    self?.updateAccessURLs()
                }
            }
            if monitor.start() {
                localHostNameMonitor = monitor
            }
        }
    }

    private func updateAccessURLs() {
        guard !accessToken.isEmpty else {
            accessURLString = nil
            alternateURLStrings = []
            return
        }
        let links = MobileDashboardAccessLinkBuilder.make(
            localHostName:
                MobileDashboardNetworkAddress.localHostName(),
            ipv4Addresses:
                MobileDashboardNetworkAddress.localIPv4Addresses(),
            port: Self.defaultPort)
        accessURLString = links.primary
        alternateURLStrings = links.alternates
    }

    private func localized(
        english: String,
        chinese: String
    ) -> String {
        AppLanguage.current == .simplifiedChinese
            ? chinese
            : english
    }

    private func persistModelSelection() {
        guard let data = try? JSONEncoder().encode(
            selectedModelKeys) else {
            return
        }
        defaults.set(data, forKey: DefaultsKey.selectedModels)
        hasPersistedModelSelection = true
    }

    private func freshManualPairingCode() -> String? {
        for _ in 0..<8 {
            guard let code = Self.generateManualPairingCode() else {
                return nil
            }
            guard code != lastManualPairingCode else { continue }
            lastManualPairingCode = code
            return code
        }
        return nil
    }

    private static func loadModelSelection(
        defaults: UserDefaults
    ) -> [MobileDashboardModelSelectionKey]? {
        guard defaults.object(forKey: DefaultsKey.selectedModels)
                != nil,
              let data = defaults.data(
                forKey: DefaultsKey.selectedModels),
              let decoded = try? JSONDecoder().decode(
                [MobileDashboardModelSelectionKey].self,
                from: data) else {
            return nil
        }
        let selection = uniqueSelectionKeys(
            decoded.filter(\.isSupported))
        guard !selection.isEmpty else { return nil }
        return Array(
            selection.prefix(maximumSelectedModelCount))
    }

    private static func uniqueSelectionKeys(
        _ keys: [MobileDashboardModelSelectionKey]
    ) -> [MobileDashboardModelSelectionKey] {
        var seen = Set<MobileDashboardModelSelectionKey>()
        return keys.filter { seen.insert($0).inserted }
    }

    nonisolated static func generateAccessToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(
            kSecRandomDefault,
            bytes.count,
            &bytes
        ) == errSecSuccess else {
            return nil
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func generateManualPairingCode() -> String? {
        let upperBound: UInt64 = 100_000_000
        let sampleSpace = UInt64(UInt32.max) + 1
        let unbiasedLimit = sampleSpace
            - sampleSpace % upperBound
        for _ in 0..<8 {
            var random = UInt32.zero
            guard SecRandomCopyBytes(
                kSecRandomDefault,
                MemoryLayout<UInt32>.size,
                &random
            ) == errSecSuccess else {
                return nil
            }
            let sample = UInt64(random)
            guard sample < unbiasedLimit else { continue }
            return String(
                format: "%08llu",
                sample % upperBound)
        }
        return nil
    }
}

struct MobileDashboardEventEnvelope: Codable {
    let oledProtectionEnabled: Bool
    let experimentalWakeMediaEnabled: Bool
    let activityBackgroundEffect:
        MobileDashboardActivityBackgroundEffect
    let taskTelemetryFields: [MobileDashboardTaskTelemetryField]
    let colorScheme: MobileDashboardColorScheme
    let idleBlackoutMarqueeEnabled: Bool
    let snapshot: MobileDashboardSnapshot

    init(
        oledProtectionEnabled: Bool,
        experimentalWakeMediaEnabled: Bool,
        activityBackgroundEffect:
            MobileDashboardActivityBackgroundEffect,
        taskTelemetryFields: [MobileDashboardTaskTelemetryField] =
            MobileDashboardTaskTelemetryField.allCases,
        colorScheme: MobileDashboardColorScheme,
        idleBlackoutMarqueeEnabled: Bool,
        snapshot: MobileDashboardSnapshot
    ) {
        self.oledProtectionEnabled = oledProtectionEnabled
        self.experimentalWakeMediaEnabled = experimentalWakeMediaEnabled
        self.activityBackgroundEffect = activityBackgroundEffect
        self.taskTelemetryFields = taskTelemetryFields
        self.colorScheme = colorScheme
        self.idleBlackoutMarqueeEnabled = idleBlackoutMarqueeEnabled
        self.snapshot = snapshot
    }
}

enum MobileDashboardViewerBroadcastPolicy {
    static func shouldInvalidateSnapshot(
        previousCount: Int,
        newCount: Int
    ) -> Bool {
        newCount > 0 && newCount > previousCount
    }
}

struct MobileDashboardAccessLinks: Equatable {
    let primary: String?
    let alternates: [String]
}

enum MobileDashboardAccessLinkBuilder {
    static func make(
        localHostName: String?,
        ipv4Addresses: [String],
        port: UInt16
    ) -> MobileDashboardAccessLinks {
        var seenAddresses = Set<String>()
        let ipLinks = ipv4Addresses
            .filter {
                MobileDashboardNetworkAddress
                    .isPrivateOrLinkLocalIPv4($0)
            }
            .filter { seenAddresses.insert($0).inserted }
            .compactMap {
                link(
                    host: $0,
                    port: port)
            }

        if let localHostName = MobileDashboardNetworkAddress
            .normalizedLocalHostName(localHostName),
           let primary = link(
               host: localHostName + ".local",
               port: port)
        {
            return MobileDashboardAccessLinks(
                primary: primary,
                alternates: ipLinks)
        }

        return MobileDashboardAccessLinks(
            primary: ipLinks.first,
            alternates: Array(ipLinks.dropFirst()))
    }

    private static func link(
        host: String,
        port: UInt16
    ) -> String? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = "/"
        return components.string
    }
}

private final class MobileDashboardLocalHostNameMonitor:
    @unchecked Sendable
{
    typealias ChangeHandler = @Sendable () -> Void

    private let queue = DispatchQueue(
        label:
            "com.techfanseric.aiquotabar.mobile-dashboard.local-host-name")
    private let changeHandler: ChangeHandler
    private var store: SCDynamicStore?

    init(changeHandler: @escaping ChangeHandler) {
        self.changeHandler = changeHandler
    }

    func start() -> Bool {
        guard store == nil else { return true }
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)
        guard let nextStore = SCDynamicStoreCreate(
            nil,
            "AIQuotaBar.MobileDashboard.LocalHostName" as CFString,
            { _, _, info in
                guard let info else { return }
                let monitor = Unmanaged<
                    MobileDashboardLocalHostNameMonitor
                >.fromOpaque(info).takeUnretainedValue()
                monitor.changeHandler()
            },
            &context)
        else {
            return false
        }

        // LocalHostName is independently configurable from ComputerName.
        // The HostNames entity explicitly includes the Bonjour local name.
        let hostNamesKey = SCDynamicStoreKeyCreateHostNames(nil)
        let computerNameKey = SCDynamicStoreKeyCreateComputerName(nil)
        guard SCDynamicStoreSetNotificationKeys(
                nextStore,
                [hostNamesKey, computerNameKey] as CFArray,
                nil),
              SCDynamicStoreSetDispatchQueue(nextStore, queue)
        else {
            return false
        }
        store = nextStore
        return true
    }

    func stop() {
        guard let store else { return }
        SCDynamicStoreSetDispatchQueue(store, nil)
        self.store = nil
    }

    deinit {
        stop()
    }
}
