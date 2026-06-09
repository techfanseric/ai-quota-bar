import Foundation

/// Cloud-only quota visuals can become misleading when the last report is old.
/// This setting controls how long those remote-only visuals stay visible.
enum CloudDataVisibilityLimit: String, CaseIterable, Codable, Identifiable {
    case oneHour
    case fiveHours
    case oneDay
    case oneWeek
    case never

    var id: String { rawValue }

    var interval: TimeInterval? {
        switch self {
        case .oneHour:
            return 3600
        case .fiveHours:
            return 5 * 3600
        case .oneDay:
            return 24 * 3600
        case .oneWeek:
            return 7 * 24 * 3600
        case .never:
            return nil
        }
    }
}
