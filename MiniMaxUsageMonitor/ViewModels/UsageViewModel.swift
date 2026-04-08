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
        }
    }

    @Published var warningThreshold: Double {
        didSet {
            UserDefaults.standard.set(warningThreshold, forKey: "warningThreshold")
        }
    }

    @Published var autoRefreshOnLaunch: Bool {
        didSet {
            UserDefaults.standard.set(autoRefreshOnLaunch, forKey: "autoRefreshOnLaunch")
        }
    }

    // MARK: - Computed Properties

    var statusBarText: String {
        guard let data = usageData else {
            return error != nil ? "—" : "..."
        }
        return data.formattedRemaining(format: displayFormat)
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
        self.autoRefreshOnLaunch = UserDefaults.standard.bool(forKey: "autoRefreshOnLaunch")

        setupWarningObserver()
    }

    // MARK: - Public Methods

    func refresh() async {
        guard !isLoading else { return }

        isLoading = true
        error = nil

        do {
            let data = try await UsageService.shared.fetchUsage()
            usageData = data
            lastRefreshTime = Date()
            checkThreshold()
        } catch let usError as UsageError {
            error = usError
        } catch {
            self.error = .networkError(error)
        }

        isLoading = false
    }

    func startAutoRefresh() {
        guard autoRefreshOnLaunch || !hasAPIKey else { return }
        restartTimer()
        Task {
            await refresh()
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
        $usageData
            .compactMap { $0 }
            .sink { [weak self] data in
                self?.checkThreshold()
            }
            .store(in: &cancellables)
    }

    private func checkThreshold() {
        guard let data = usageData else {
            showWarningPanel = false
            return
        }

        showWarningPanel = data.percentageRemaining <= warningThreshold
    }
}
