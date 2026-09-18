import Foundation

/// One stable, unfiltered list for every display destination. Menu visibility
/// must never remove a model from the settings used to restore it.
struct ModelDisplayCatalog {
    struct Account: Identifiable {
        let key: LeftClickMenuAccountKey
        let provider: UsageProvider
        let name: String
        var models: [ModelUsageData]
        var id: LeftClickMenuAccountKey { key }
    }

    let models: [ModelUsageData]
    let accounts: [Account]

    init(models candidates: [ModelUsageData]) {
        var seen = Set<MobileDashboardModelSelectionKey>()
        models = candidates.filter { seen.insert($0.mobileDashboardSelectionKey).inserted }
        var groups: [Account] = []
        for model in models {
            let key = LeftClickMenuAccountKey(model: model)
            if let index = groups.firstIndex(where: { $0.key == key }) {
                groups[index].models.append(model)
            } else {
                groups.append(Account(key: key, provider: model.provider,
                    name: model.accountName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    models: [model]))
            }
        }
        accounts = groups
    }

    func unavailableSelections(_ selected: [MobileDashboardModelSelectionKey]) -> [MobileDashboardModelSelectionKey] {
        let available = Set(models.map(\.mobileDashboardSelectionKey))
        return selected.filter { !available.contains($0) }
    }
}
