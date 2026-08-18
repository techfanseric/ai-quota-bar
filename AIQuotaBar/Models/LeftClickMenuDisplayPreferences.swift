import Foundation

struct LeftClickMenuAccountKey: Codable, Hashable {
    let providerRaw: String
    let normalizedAccount: String

    init(providerRaw: String, accountName: String) {
        self.providerRaw = Self.normalize(providerRaw)
        self.normalizedAccount = Self.normalize(accountName)
    }

    init(model: ModelUsageData) {
        self.init(
            providerRaw: model.provider.rawValue,
            accountName: model.accountName ?? "")
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct LeftClickMenuDisplayPreferences: Codable, Equatable {
    static let storageKey = "leftClickMenuDisplayPreferences"

    var hiddenAccounts: Set<LeftClickMenuAccountKey> = []
    var hiddenModels: Set<MobileDashboardModelSelectionKey> = []

    var hasHiddenItems: Bool {
        !hiddenAccounts.isEmpty || !hiddenModels.isEmpty
    }

    func isAccountVisible(_ key: LeftClickMenuAccountKey) -> Bool {
        !hiddenAccounts.contains(key)
    }

    func isModelVisible(_ model: ModelUsageData) -> Bool {
        isAccountVisible(LeftClickMenuAccountKey(model: model))
            && !hiddenModels.contains(model.mobileDashboardSelectionKey)
    }

    mutating func setAccountVisible(
        _ isVisible: Bool,
        key: LeftClickMenuAccountKey
    ) {
        if isVisible {
            hiddenAccounts.remove(key)
        } else {
            hiddenAccounts.insert(key)
        }
    }

    mutating func setModelVisible(
        _ isVisible: Bool,
        key: MobileDashboardModelSelectionKey
    ) {
        if isVisible {
            hiddenModels.remove(key)
        } else {
            hiddenModels.insert(key)
        }
    }

    mutating func showAll() {
        hiddenAccounts.removeAll()
        hiddenModels.removeAll()
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
