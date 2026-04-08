import Foundation

/// API response model for MiniMax usage data
/// Endpoint: GET https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains
struct UsageData: Codable {
    /// Remaining tokens/credits
    let remains: Int
    /// Total allocated amount (for percentage calculation)
    let total: Int
    /// Timestamp of the response
    let timestamp: Date
    /// Per-model quota details returned by the API
    let models: [ModelUsageData]

    /// Percentage remaining (0-100)
    var percentageRemaining: Double {
        guard total > 0 else { return 0 }
        return (Double(remains) / Double(total)) * 100
    }

    /// Formatted remaining display string
    func formattedRemaining(format: DisplayFormat, language: AppLanguage) -> String {
        let percent = Int(percentageRemaining)
        switch format {
        case .numberOnly:
            return "\(percent)%"
        case .numberWithUnit:
            switch language {
            case .english:
                return "\(percent)% remaining"
            case .simplifiedChinese:
                return "剩余 \(percent)%"
            }
        case .leveled:
            if percentageRemaining > 50 {
                return "\(percent)%"
            } else {
                let days = estimateDaysRemaining()
                switch language {
                case .english:
                    return "[Warning] \(percent)% (~\(days) days)"
                case .simplifiedChinese:
                    return "[提醒] \(percent)% (约 \(days) 天)"
                }
            }
        }
    }

    /// Estimate days until quota exhaustion (simplified)
    private func estimateDaysRemaining() -> Int {
        // Placeholder calculation based on typical usage
        // Real implementation would track usage trend over time
        return max(1, Int(Double(remains) / Double(total) * 30))
    }

    var modelCount: Int {
        models.count
    }
}

struct ModelUsageData: Codable, Identifiable {
    let modelName: String
    let currentIntervalTotal: Int
    let currentIntervalUsed: Int
    let weeklyTotal: Int
    let weeklyUsed: Int
    let startTime: Date?
    let endTime: Date?
    let weeklyStartTime: Date?
    let weeklyEndTime: Date?

    var id: String { modelName }

    var currentIntervalRemaining: Int {
        max(0, currentIntervalTotal - currentIntervalUsed)
    }

    var weeklyRemaining: Int {
        max(0, weeklyTotal - weeklyUsed)
    }

    var hasWeeklyLimit: Bool {
        weeklyTotal > 0
    }

    var currentIntervalPercentageRemaining: Double {
        guard currentIntervalTotal > 0 else { return 0 }
        return (Double(currentIntervalRemaining) / Double(currentIntervalTotal)) * 100
    }
}

struct MiniMaxUsageAPIResponse: Decodable {
    let modelRemains: [MiniMaxModelRemain]
    let baseResp: MiniMaxBaseResponse

    enum CodingKeys: String, CodingKey {
        case modelRemains = "model_remains"
        case baseResp = "base_resp"
    }
}

struct MiniMaxModelRemain: Decodable {
    let modelName: String
    let startTime: Int64
    let endTime: Int64
    let currentIntervalTotalCount: Int
    let currentIntervalUsageCount: Int
    let currentWeeklyTotalCount: Int
    let currentWeeklyUsageCount: Int
    let weeklyStartTime: Int64
    let weeklyEndTime: Int64

    enum CodingKeys: String, CodingKey {
        case modelName = "model_name"
        case startTime = "start_time"
        case endTime = "end_time"
        case currentIntervalTotalCount = "current_interval_total_count"
        case currentIntervalUsageCount = "current_interval_usage_count"
        case currentWeeklyTotalCount = "current_weekly_total_count"
        case currentWeeklyUsageCount = "current_weekly_usage_count"
        case weeklyStartTime = "weekly_start_time"
        case weeklyEndTime = "weekly_end_time"
    }
}

struct MiniMaxBaseResponse: Decodable {
    let statusCode: Int
    let statusMessage: String

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case statusMessage = "status_msg"
    }
}

/// Menu bar display format options
enum DisplayFormat: Int, CaseIterable, Codable {
    case numberOnly = 0
    case numberWithUnit = 1
    case leveled = 2

    var description: String {
        switch self {
        case .numberOnly: return "Number only (e.g., 85%)"
        case .numberWithUnit: return "Number with unit (e.g., 85% remaining)"
        case .leveled: return "Leveled (detailed when low)"
        }
    }
}

/// Error types for usage fetching
enum UsageError: Error, LocalizedError {
    case invalidURL
    case networkError(Error)
    case invalidResponse
    case apiError(String)
    case keychainError
    case notConfigured

    var errorDescription: String? {
        AppLanguage.current.errorDescription(for: self)
    }
}
