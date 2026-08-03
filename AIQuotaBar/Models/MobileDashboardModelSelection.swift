import Foundation

/// A versioned, normalized identity for a model selected for the mobile
/// dashboard. This type is persisted locally, but is deliberately not part of
/// the mobile snapshot payload.
struct MobileDashboardModelSelectionKey: Codable, Hashable {
    static let currentVersion = 1

    let version: Int
    let providerRaw: String
    let normalizedAccount: String
    let normalizedModel: String

    init(
        version: Int = Self.currentVersion,
        providerRaw: String,
        normalizedAccount: String,
        normalizedModel: String
    ) {
        self.version = version
        self.providerRaw = Self.normalize(providerRaw)
        self.normalizedAccount = Self.normalize(normalizedAccount)
        self.normalizedModel = Self.normalize(normalizedModel)
    }

    init(model: ModelUsageData) {
        self.init(
            providerRaw: model.provider.rawValue,
            normalizedAccount: model.accountName ?? "",
            normalizedModel: model.modelName)
    }

    var isSupported: Bool {
        version == Self.currentVersion
            && !providerRaw.isEmpty
            && !normalizedModel.isEmpty
    }

    func matches(_ model: ModelUsageData) -> Bool {
        self == model.mobileDashboardSelectionKey
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

extension ModelUsageData {
    var mobileDashboardSelectionKey:
        MobileDashboardModelSelectionKey
    {
        MobileDashboardModelSelectionKey(model: self)
    }

    func matchesMobileDashboardSelection(
        _ selection: MobileDashboardModelSelectionKey
    ) -> Bool {
        selection.matches(self)
    }
}
