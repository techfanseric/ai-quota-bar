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
    /// 收起的供应商区。App 开关（跟随模式）与用户手动点击都会写这个集合，
    /// 最后一次操作生效；菜单重开与 App 重启后保持。
    var collapsedProviders: Set<UsageProvider> = []
    /// 仅在用户调整过顺序时持久化；nil 表示沿用 `UsageProvider.leftClickMenuDefaultOrder`。
    var customProviderOrder: [UsageProvider]?

    var providerOrder: [UsageProvider] {
        customProviderOrder ?? UsageProvider.leftClickMenuDefaultOrder
    }

    var hasCustomProviderOrder: Bool {
        customProviderOrder != nil
    }

    /// 把供应商在菜单顺序里上移（负 offset）或下移（正 offset），越界时钳制到端点。
    /// 调回默认顺序时会清掉自定义持久化，保持存储干净。
    mutating func moveProvider(_ provider: UsageProvider, byOffset offset: Int) {
        guard offset != 0,
              let from = providerOrder.firstIndex(of: provider) else { return }
        let to = min(providerOrder.count - 1, max(0, from + offset))
        guard from != to else { return }

        var order = providerOrder
        order.remove(at: from)
        order.insert(provider, at: to)
        customProviderOrder = order == UsageProvider.leftClickMenuDefaultOrder ? nil : order
    }

    mutating func resetProviderOrder() {
        customProviderOrder = nil
    }

    init() {}

    /// 兼容旧版本存储：缺失或非法的顺序字段回退到默认顺序，而不是丢弃全部偏好。
    /// 自定义顺序里缺失的供应商按 allCases 相对顺序补到末尾，去重保序。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hiddenAccounts = try container.decodeIfPresent(
            Set<LeftClickMenuAccountKey>.self,
            forKey: .hiddenAccounts) ?? []
        hiddenModels = try container.decodeIfPresent(
            Set<MobileDashboardModelSelectionKey>.self,
            forKey: .hiddenModels) ?? []
        collapsedProviders = try container.decodeIfPresent(
            Set<UsageProvider>.self,
            forKey: .collapsedProviders) ?? []
        customProviderOrder = Self.normalizedCustomOrder(
            try container.decodeIfPresent([String].self, forKey: .customProviderOrder)?
                .compactMap(UsageProvider.init(rawValue:)))
    }

    private static func normalizedCustomOrder(_ saved: [UsageProvider]?) -> [UsageProvider]? {
        guard let saved, !saved.isEmpty else { return nil }
        var seen = Set<UsageProvider>()
        let deduped = saved.filter { seen.insert($0).inserted }
        let order = deduped + UsageProvider.allCases.filter { !seen.contains($0) }
        return order == UsageProvider.leftClickMenuDefaultOrder ? nil : order
    }

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

    func isProviderCollapsed(_ provider: UsageProvider) -> Bool {
        collapsedProviders.contains(provider)
    }

    mutating func setProviderCollapsed(
        _ isCollapsed: Bool,
        provider: UsageProvider
    ) {
        if isCollapsed {
            collapsedProviders.insert(provider)
        } else {
            collapsedProviders.remove(provider)
        }
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
