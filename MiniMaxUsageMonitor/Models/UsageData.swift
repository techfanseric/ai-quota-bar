import Foundation

/// API response model for MiniMax usage data
/// Endpoint: GET https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains
struct UsageData: Codable {
    /// Models that still have quota in the current interval
    let remains: Int
    /// Total tracked models
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
    func formattedRemaining(format: DisplayFormat, language: AppLanguage, warningThreshold: Double) -> String {
        switch format {
        case .numberOnly:
            return language.menuBarCompactText(ready: readyModelsCount, total: modelCount)
        case .numberWithUnit:
            return language.readyModelsText(readyModelsCount)
        case .leveled:
            if exhaustedModelsCount > 0 {
                return language.fullModelsText(exhaustedModelsCount)
            }

            let lowModels = lowModelsCount(threshold: warningThreshold)
            if lowModels > 0 {
                return language.lowModelsText(lowModels)
            }

            return language.readyModelsText(readyModelsCount)
        case .specificModel:
            return "—"
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

    var readyModelsCount: Int {
        models.filter(\.isCurrentIntervalAvailable).count
    }

    var exhaustedModelsCount: Int {
        models.filter { !$0.isCurrentIntervalAvailable }.count
    }

    var weeklyExhaustedModelsCount: Int {
        models.filter(\.isWeeklyExhausted).count
    }

    func lowModelsCount(threshold: Double) -> Int {
        models.filter {
            $0.isCurrentIntervalAvailable && $0.currentIntervalPercentageRemaining <= threshold
        }.count
    }

    func sortedModels(warningThreshold: Double) -> [ModelUsageData] {
        models.sorted { lhs, rhs in
            sortWeight(for: lhs, warningThreshold: warningThreshold) < sortWeight(for: rhs, warningThreshold: warningThreshold)
        }
    }

    var nextResetDate: Date? {
        models.compactMap(\.endTime).min()
    }

    var mostUrgentModel: ModelUsageData? {
        sortedModels(warningThreshold: 20).first
    }

    private func sortWeight(for model: ModelUsageData, warningThreshold: Double) -> (Int, Double, String) {
        let severity: Int
        if !model.isCurrentIntervalAvailable {
            severity = 0
        } else if model.currentIntervalPercentageRemaining <= warningThreshold {
            severity = 1
        } else {
            severity = 2
        }

        return (severity, model.currentIntervalPercentageRemaining, model.modelName)
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
        currentIntervalUsed
    }

    var isCurrentIntervalAvailable: Bool {
        currentIntervalRemaining > 0
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

    var isWeeklyExhausted: Bool {
        hasWeeklyLimit && weeklyRemaining == 0
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
    case specificModel = 3

    var description: String {
        switch self {
        case .numberOnly: return "Compact model summary"
        case .numberWithUnit: return "Model availability summary"
        case .leveled: return "Risk-aware model summary"
        case .specificModel: return "Primary model detail"
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

extension ModelUsageData {
    func formattedMenuBarText(language: AppLanguage) -> String {
        let remaining = currentIntervalRemaining
        let resetText = formatResetTime(endTime: endTime)
        return "\(remaining)/\(resetText)"
    }

    private func formatResetTime(endTime: Date?) -> String {
        guard let endTime = endTime else { return "0m" }
        let interval = endTime.timeIntervalSince(Date())
        let hours = interval / 3600.0

        if hours <= 0 {
            return "0m"
        }
        if hours < 1 {
            let minutes = Int(interval / 60)
            return "\(minutes)m"
        }
        return String(format: "%.2fh", hours)
    }
}
