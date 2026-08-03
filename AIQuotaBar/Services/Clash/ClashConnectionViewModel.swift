import Foundation

@MainActor
@Observable
final class ClashConnectionViewModel {
    var language: AppLanguage = .current

    private(set) var phase: ClashConnectionPanelPhase = .idle
    private(set) var connections: [ClashActiveConnection] = []
    private(set) var uploadSpeed: Double = 0
    private(set) var downloadSpeed: Double = 0
    private(set) var observedAt: Date?
    private(set) var history: [ClashConnectionHistorySample]
    private(set) var clientName: String?
    private(set) var isLive = false

    private let discovery: ClashConfigurationDiscovery
    private let historyStore: ClashConnectionHistoryStore
    private var activityCalculator = ClashConnectionActivityCalculator()
    private var monitoringTask: Task<Void, Never>?
    private var monitoringGeneration = 0
    private var isMonitoringEnabled = false
    private var liveUpdateOwners: Set<String> = []

    private let liveIntervalMilliseconds = 1_000
    private let backgroundIntervalMilliseconds = 60_000
    private let liveRetryDelay: TimeInterval = 3
    private let backgroundRetryDelay: TimeInterval = 60

    init(
        discovery: ClashConfigurationDiscovery = ClashConfigurationDiscovery(),
        historyStore: ClashConnectionHistoryStore = .shared
    ) {
        self.discovery = discovery
        self.historyStore = historyStore
        history = historyStore.load()
    }

    var activeConnectionCount: Int {
        connections.count
    }

    func startBackgroundMonitoring() {
        guard !isMonitoringEnabled else { return }
        isMonitoringEnabled = true
        restartMonitoring()
    }

    func beginLiveUpdates(owner: String = "popover") {
        let wasLive = !liveUpdateOwners.isEmpty
        liveUpdateOwners.insert(owner)
        guard !wasLive else { return }
        isLive = true
        if !isMonitoringEnabled {
            isMonitoringEnabled = true
        }
        restartMonitoring()
    }

    func endLiveUpdates(owner: String = "popover") {
        liveUpdateOwners.remove(owner)
        guard liveUpdateOwners.isEmpty, isLive else { return }
        isLive = false
        historyStore.save(history)
        guard isMonitoringEnabled else { return }
        restartMonitoring()
    }

    func retry() {
        if !isMonitoringEnabled {
            isMonitoringEnabled = true
        }
        restartMonitoring()
    }

    func stop() {
        isMonitoringEnabled = false
        isLive = false
        liveUpdateOwners.removeAll()
        monitoringGeneration += 1
        monitoringTask?.cancel()
        monitoringTask = nil
        historyStore.save(history)
    }

    private func restartMonitoring() {
        monitoringGeneration += 1
        let generation = monitoringGeneration
        monitoringTask?.cancel()
        activityCalculator.reset()

        if connections.isEmpty {
            phase = .loading
        }

        monitoringTask = Task { @MainActor [weak self] in
            await self?.monitor(generation: generation)
        }
    }

    private func monitor(generation: Int) async {
        while isMonitoringEnabled,
              generation == monitoringGeneration,
              !Task.isCancelled {
            do {
                let configuration = try discovery.discover()
                let client = ClashAPIClient(configuration: configuration)
                _ = try await client.version()

                guard generation == monitoringGeneration else { return }
                clientName = configuration.clientName

                let interval = isLive
                    ? liveIntervalMilliseconds
                    : backgroundIntervalMilliseconds
                for try await response in client.connectionSnapshots(
                    intervalMilliseconds: interval) {
                    guard generation == monitoringGeneration,
                          !Task.isCancelled else {
                        return
                    }
                    apply(response, observedAt: Date())
                }

                guard generation == monitoringGeneration else { return }
                throw ClashIntegrationError.controllerUnavailable
            } catch is CancellationError {
                return
            } catch {
                guard generation == monitoringGeneration,
                      !Task.isCancelled else {
                    return
                }
                setUnavailable(error)

                let retryDelay = isLive
                    ? liveRetryDelay
                    : backgroundRetryDelay
                do {
                    try await Task.sleep(
                        for: .seconds(retryDelay))
                } catch {
                    return
                }
            }
        }
    }

    private func apply(
        _ response: ClashConnectionsResponse,
        observedAt: Date
    ) {
        let previousLatestTimestamp = history.last?.timestamp
        let snapshot = activityCalculator.update(
            response: response,
            observedAt: observedAt)

        connections = snapshot.connections
        uploadSpeed = snapshot.uploadSpeed
        downloadSpeed = snapshot.downloadSpeed
        self.observedAt = observedAt
        history = ClashConnectionHistory.upserting(
            snapshot: snapshot,
            into: history)
        phase = .ready

        if history.last?.timestamp != previousLatestTimestamp {
            historyStore.save(history)
        }
    }

    private func setUnavailable(_ error: Error) {
        connections = []
        uploadSpeed = 0
        downloadSpeed = 0
        observedAt = nil
        activityCalculator.reset()

        let displayError: Error
        if error is ClashIntegrationError {
            displayError = error
        } else {
            displayError = ClashIntegrationError.controllerUnavailable
        }
        phase = .unavailable(
            language.clashErrorMessage(displayError))
    }
}
