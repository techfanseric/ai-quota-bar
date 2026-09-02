import Foundation

enum QuotaChartDisplayMode: String, Codable, CaseIterable, Identifiable {
    case automatic
    case areaChart
    case progressBar

    var id: String { rawValue }
}

struct QuotaChartDisplayPreferences: Codable, Equatable {
    static let storageKey = "quotaChartDisplayPreferences"

    private(set) var overrides: [MobileDashboardModelSelectionKey: QuotaChartDisplayMode] = [:]

    func mode(for model: ModelUsageData) -> QuotaChartDisplayMode {
        overrides[model.mobileDashboardSelectionKey] ?? .automatic
    }

    mutating func setMode(_ mode: QuotaChartDisplayMode, for model: ModelUsageData) {
        let key = model.mobileDashboardSelectionKey
        if mode == .automatic {
            overrides.removeValue(forKey: key)
        } else {
            overrides[key] = mode
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self()
        }
        return value
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
