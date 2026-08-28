import Foundation

@MainActor
@Observable
final class ClashRouteViewModel {
    private enum DefaultsKey {
        static let filterQuery = "clashRouteFilterQuery"
        static let usesRegularExpression = "clashRouteFilterUsesRegularExpression"
        static let autoSelectBest = "clashRouteAutoSelectBest"
        static let lastRecoveryAttempt = "clashRouteLastRecoveryAttempt"
    }

    var filterQuery: String {
        didSet {
            defaults.set(filterQuery, forKey: DefaultsKey.filterQuery)
        }
    }

    var usesRegularExpression: Bool {
        didSet {
            defaults.set(
                usesRegularExpression,
                forKey: DefaultsKey.usesRegularExpression)
        }
    }

    var autoRecoveryEnabled: Bool {
        didSet {
            defaults.set(
                autoRecoveryEnabled,
                forKey: DefaultsKey.autoSelectBest)
        }
    }

    var language: AppLanguage = .current

    private(set) var isFilterEditing = false
    private(set) var phase: ClashPanelPhase = .idle
    private(set) var routes: [ClashRoute] = []
    private(set) var groupName: String?
    private(set) var selectedRouteName: String?
    private(set) var clientName: String?
    private(set) var isSpeedTesting = false
    private(set) var isSwitching = false
    private(set) var statusMessage: String?
    private(set) var switchHistory: [ClashRouteSwitchRecord]

    private let defaults: UserDefaults
    private let discovery: ClashConfigurationDiscovery
    private let switchHistoryStore: ClashRouteSwitchHistoryStore
    private var apiClient: ClashAPIClient?
    private var isPreparingDisplay = false
    private let recoveryCooldown: TimeInterval = 10 * 60

    init(
        defaults: UserDefaults = .standard,
        discovery: ClashConfigurationDiscovery = ClashConfigurationDiscovery()
    ) {
        self.defaults = defaults
        self.discovery = discovery
        switchHistoryStore = ClashRouteSwitchHistoryStore(
            defaults: defaults)
        switchHistory = switchHistoryStore.load()
        filterQuery = defaults.string(forKey: DefaultsKey.filterQuery) ?? ""
        usesRegularExpression = defaults.bool(forKey: DefaultsKey.usesRegularExpression)
        autoRecoveryEnabled = defaults.bool(forKey: DefaultsKey.autoSelectBest)
    }

    var filterResult: ClashRouteFilterResult {
        ClashRouteFilter.filter(
            routes,
            query: filterQuery,
            usesRegularExpression: usesRegularExpression)
    }

    var filteredRoutes: [ClashRoute] {
        filterResult.routes
    }

    var filterErrorMessage: String? {
        filterResult.errorMessage
    }

    var hasActiveFilter: Bool {
        !filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func beginFilterEditing() {
        isFilterEditing = true
    }

    func endFilterEditing() {
        isFilterEditing = false
    }

    func prepareForDisplay(automaticallyTest: Bool) async {
        guard !isPreparingDisplay else { return }
        isPreparingDisplay = true
        defer { isPreparingDisplay = false }

        await refresh()
        guard automaticallyTest, phase == .ready else { return }
        await testRoutes()
    }

    func refresh() async {
        if routes.isEmpty {
            phase = .loading
        }
        statusMessage = nil

        do {
            let configuration = try discovery.discover()
            let client = ClashAPIClient(configuration: configuration)
            _ = try await client.version()
            let snapshot = try await client.loadRouteSnapshot()

            apiClient = client
            clientName = configuration.clientName
            apply(snapshot)
            phase = .ready
            statusMessage = language.clashReadyStatus(groupName: snapshot.groupName)
        } catch {
            apiClient = nil
            phase = .unavailable(language.clashErrorMessage(error))
        }
    }

    /// Measures and sorts routes without changing the selected route.
    /// Automatic switching is intentionally confined to
    /// `attemptAutomaticRecovery(connectivityProbe:)`.
    func testRoutes() async {
        guard !isSpeedTesting, !isSwitching else { return }
        guard phase == .ready, apiClient != nil, groupName != nil else {
            await refresh()
            guard phase == .ready else { return }
            return await testRoutes()
        }

        do {
            try await performSpeedTest()
            statusMessage = language.clashSpeedTestFinished()
        } catch {
            statusMessage = language.clashSpeedTestFailed(
                language.clashErrorMessage(error))
        }
    }

    @discardableResult
    func selectRoute(_ routeName: String) async -> Bool {
        guard !isSwitching,
              let apiClient,
              let groupName else {
            return false
        }

        isSwitching = true
        defer { isSwitching = false }

        do {
            let previousRouteName = selectedRouteName
            try await apiClient.select(
                routeName: routeName,
                in: groupName)
            setSelectedRoute(routeName)
            recordSwitch(
                from: previousRouteName,
                to: routeName)
            statusMessage = language.clashSelectedRoute(routeName)
            return true
        } catch {
            statusMessage = language.clashSelectionFailed(
                language.clashErrorMessage(error))
            return false
        }
    }

    func attemptAutomaticRecovery(
        connectivityProbe: @escaping @MainActor () async -> Bool
    ) async -> ClashRecoveryOutcome {
        guard autoRecoveryEnabled else {
            return .needsAttention(shouldTestWhenShown: true)
        }
        guard hasActiveFilter else {
            return .needsAttention(shouldTestWhenShown: true)
        }
        guard filterErrorMessage == nil else {
            return .needsAttention(shouldTestWhenShown: false)
        }
        guard !isPreparingDisplay, !isSpeedTesting, !isSwitching else {
            return .suppressed
        }

        if let lastAttempt = defaults.object(
            forKey: DefaultsKey.lastRecoveryAttempt) as? Date,
            Date().timeIntervalSince(lastAttempt) < recoveryCooldown {
            return .suppressed
        }
        defaults.set(Date(), forKey: DefaultsKey.lastRecoveryAttempt)

        await refresh()
        guard phase == .ready else {
            return .needsAttention(shouldTestWhenShown: false)
        }

        do {
            try await performSpeedTest()
        } catch {
            statusMessage = language.clashSpeedTestFailed(
                language.clashErrorMessage(error))
            return .needsAttention(shouldTestWhenShown: false)
        }

        let candidates = filteredRoutes
            .filter(\.hasUsableDelay)
            .prefix(3)
        guard !candidates.isEmpty else {
            statusMessage = language.clashRecoveryFailed()
            return .needsAttention(shouldTestWhenShown: false)
        }

        let originalRoute = selectedRouteName ?? "—"
        for candidate in candidates {
            if candidate.name != selectedRouteName {
                let switched = await selectRoute(candidate.name)
                guard switched else { continue }
            }

            if await connectivityProbe() {
                return .recovered(
                    ClashRecoveryResult(
                        previousRoute: originalRoute,
                        selectedRoute: candidate.name,
                        delay: candidate.delay ?? 0))
            }
        }

        statusMessage = language.clashRecoveryFailed()
        return .needsAttention(shouldTestWhenShown: false)
    }

    private func performSpeedTest() async throws {
        guard let apiClient, let groupName else {
            throw ClashIntegrationError.controllerUnavailable
        }

        isSpeedTesting = true
        statusMessage = language.clashTestingRoutes()
        defer { isSpeedTesting = false }

        let delays = try await apiClient.testGroup(groupName)
        routes = ClashRouteSorter.sorted(routes.map { route in
            var updatedRoute = route
            updatedRoute.delay = delays[route.name] ?? 0
            return updatedRoute
        })
    }

    private func apply(_ snapshot: ClashRouteSnapshot) {
        let previousGroupName = groupName
        let previousRouteName = selectedRouteName
        groupName = snapshot.groupName
        selectedRouteName = snapshot.selectedRouteName
        routes = snapshot.routes

        if previousGroupName == snapshot.groupName,
           let selectedRouteName = snapshot.selectedRouteName {
            recordSwitch(
                from: previousRouteName,
                to: selectedRouteName)
        }
    }

    private func setSelectedRoute(_ routeName: String) {
        selectedRouteName = routeName
        routes = routes.map { route in
            var updatedRoute = route
            updatedRoute.isSelected = route.name == routeName
            return updatedRoute
        }
    }

    private func recordSwitch(
        from previousRouteName: String?,
        to selectedRouteName: String
    ) {
        guard let previousRouteName,
              previousRouteName != selectedRouteName else {
            return
        }

        switchHistory = switchHistoryStore.recordSwitch(
            from: previousRouteName,
            to: selectedRouteName)
    }
}
