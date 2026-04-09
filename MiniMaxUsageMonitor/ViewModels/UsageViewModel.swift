import Foundation
import AppKit
import Combine

/// Main view model managing usage state and refresh logic
@MainActor
final class UsageViewModel: ObservableObject {
    // MARK: - Published State

    @Published var usageData: UsageData?
    @Published var error: UsageError?
    @Published var isLoading: Bool = false
    @Published var lastRefreshTime: Date?
    @Published var showWarningPanel: Bool = false
    @Published private(set) var modelQuotaSamples: [String: [ModelQuotaSample]] = [:]

    // MARK: - Settings

    @Published var refreshInterval: Int {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
            restartTimer()
        }
    }

    @Published var displayFormat: DisplayFormat {
        didSet {
            UserDefaults.standard.set(displayFormat.rawValue, forKey: "displayFormat")
            updateStatusBarText()
        }
    }

    @Published var warningThreshold: Double {
        didSet {
            UserDefaults.standard.set(warningThreshold, forKey: "warningThreshold")
        }
    }

    @Published var selectedModelName: String? {
        didSet {
            UserDefaults.standard.set(selectedModelName, forKey: "selectedModelName")
            updateStatusBarText()
        }
    }

    @Published var autoRefreshOnLaunch: Bool {
        didSet {
            UserDefaults.standard.set(autoRefreshOnLaunch, forKey: "autoRefreshOnLaunch")
        }
    }

    @Published var appLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(appLanguage.rawValue, forKey: AppLanguage.storageKey)
            updateStatusBarText()
        }
    }

    // MARK: - Computed Properties

    @Published var statusBarText: String = "..."

    var availableModels: [ModelUsageData] {
        guard let data = usageData else { return [] }
        return data.models
            .filter(\.isCurrentIntervalAvailable)
            .sorted { $0.currentIntervalPercentageRemaining < $1.currentIntervalPercentageRemaining }
    }

    private func updateStatusBarText() {
        guard let data = usageData else {
            statusBarText = error != nil ? "—" : "..."
            return
        }

        // Always use primary model format - show selected model or first available
        if let modelName = selectedModelName,
           let model = data.models.first(where: { $0.modelName == modelName }) {
            statusBarText = model.formattedMenuBarText(language: appLanguage)
        } else if let firstAvailable = availableModels.first {
            statusBarText = firstAvailable.formattedMenuBarText(language: appLanguage)
        } else {
            statusBarText = "—"
        }
    }

    var hasAPIKey: Bool {
        KeychainService.shared.hasAPIKey
    }

    // MARK: - Private

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init() {
        self.refreshInterval = UserDefaults.standard.object(forKey: "refreshInterval") as? Int ?? 60
        self.displayFormat = DisplayFormat(rawValue: UserDefaults.standard.integer(forKey: "displayFormat")) ?? .leveled
        self.warningThreshold = UserDefaults.standard.double(forKey: "warningThreshold") > 0
            ? UserDefaults.standard.double(forKey: "warningThreshold")
            : 20.0
        self.autoRefreshOnLaunch = UserDefaults.standard.object(forKey: "autoRefreshOnLaunch") as? Bool ?? true
        self.appLanguage = UserDefaults.standard.string(forKey: AppLanguage.storageKey)
            .flatMap(AppLanguage.init(rawValue:))
            ?? AppLanguage.fallback
        self.selectedModelName = UserDefaults.standard.string(forKey: "selectedModelName")

        setupWarningObserver()
        updateStatusBarText()
    }

    // MARK: - Public Methods

    func refresh() async {
        guard !isLoading else { return }

        isLoading = true
        error = nil

        do {
            let data = try await UsageService.shared.fetchUsage()
            let sampleTimestamp = Date()
            usageData = data
            lastRefreshTime = sampleTimestamp
            recordSamples(from: data, timestamp: sampleTimestamp)
            updateStatusBarText()
            checkThreshold()
        } catch let usError as UsageError {
            error = usError
            updateStatusBarText()
        } catch {
            self.error = .networkError(error)
            updateStatusBarText()
        }

        isLoading = false
    }

    func startAutoRefresh() {
        guard hasAPIKey else { return }
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
        let success = KeychainService.shared.saveAPIKey(key)
        if success {
            Task {
                await refresh()
            }
        }
        return success
    }

    func testAPIKey(_ key: String) async throws -> Bool {
        return try await UsageService.shared.testConnection(apiKey: key)
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

    private func setupWarningObserver() {
        Publishers.CombineLatest($usageData, $warningThreshold)
            .sink { [weak self] _, _ in
                self?.checkThreshold()
            }
            .store(in: &cancellables)
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
                remaining: model.currentIntervalRemaining
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
