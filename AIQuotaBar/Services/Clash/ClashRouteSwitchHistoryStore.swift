import Foundation

struct ClashRouteSwitchRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let switchedAt: Date
    let fromRoute: String
    let toRoute: String

    init(
        id: UUID = UUID(),
        switchedAt: Date = Date(),
        fromRoute: String,
        toRoute: String
    ) {
        self.id = id
        self.switchedAt = switchedAt
        self.fromRoute = fromRoute
        self.toRoute = toRoute
    }
}

struct ClashRouteSwitchHistoryStore {
    private enum Constants {
        static let defaultsKey = "clashRouteSwitchHistory"
        static let maximumRecordCount = 3
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [ClashRouteSwitchRecord] {
        guard let data = defaults.data(
            forKey: Constants.defaultsKey),
            let records = try? JSONDecoder().decode(
                [ClashRouteSwitchRecord].self,
                from: data) else {
            return []
        }

        return Array(
            records
                .sorted { $0.switchedAt > $1.switchedAt }
                .prefix(Constants.maximumRecordCount))
    }

    @discardableResult
    func recordSwitch(
        from fromRoute: String,
        to toRoute: String,
        at switchedAt: Date = Date()
    ) -> [ClashRouteSwitchRecord] {
        guard fromRoute != toRoute else {
            return load()
        }

        let newRecord = ClashRouteSwitchRecord(
            switchedAt: switchedAt,
            fromRoute: fromRoute,
            toRoute: toRoute)
        let records = Array(
            ([newRecord] + load())
                .sorted { $0.switchedAt > $1.switchedAt }
                .prefix(Constants.maximumRecordCount))

        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Constants.defaultsKey)
        }
        return records
    }
}
