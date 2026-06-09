import Foundation

enum CloudDataRetentionLimit: Int, CaseIterable, Codable, Identifiable {
    static let storageKey = "cloudDataRetentionLimit"

    case sevenDays = 7
    case fourteenDays = 14
    case thirtyDays = 30
    case sixtyDays = 60
    case ninetyDays = 90
    case oneHundredEightyDays = 180

    var id: Int { rawValue }

    static var current: CloudDataRetentionLimit {
        CloudDataRetentionLimit(
            rawValue: UserDefaults.standard.object(forKey: storageKey) as? Int ?? 0
        ) ?? .thirtyDays
    }
}
