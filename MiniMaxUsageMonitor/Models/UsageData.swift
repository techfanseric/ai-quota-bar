import Foundation

/// API response model for MiniMax usage data
/// Endpoint: GET https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains
struct UsageData: Codable {
    /// Usage provider that produced this response
    let provider: UsageProvider
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

    var weeklyFullModelsCount: Int {
        models.filter(\.isWeeklyFull).count
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
    let provider: UsageProvider
    let modelName: String
    let currentIntervalTotal: Int
    let currentIntervalUsed: Int  // API: 这是剩余数量，不是已用！
    let weeklyTotal: Int
    let weeklyUsed: Int  // API: 这是周剩余数量，不是周已用！
    let remainsTime: Int  // 距离重置的毫秒数
    let startTime: Date?
    let endTime: Date?
    let weeklyStartTime: Date?
    let weeklyEndTime: Date?

    var id: String { "\(provider.rawValue):\(modelName)" }

    // 剩余 = API 返回的 usage_count
    var currentIntervalRemaining: Int {
        currentIntervalUsed
    }

    // 已用 = 总量 - 剩余
    var currentIntervalUsedCount: Int {
        max(0, currentIntervalTotal - currentIntervalUsed)
    }

    var isCurrentIntervalAvailable: Bool {
        currentIntervalRemaining > 0
    }

    // 周剩余 = API 返回的 weekly_usage_count
    var weeklyRemaining: Int {
        weeklyUsed
    }

    // 周已用 = 周总量 - 周剩余
    var weeklyUsedCount: Int {
        max(0, weeklyTotal - weeklyUsed)
    }

    var hasWeeklyLimit: Bool {
        weeklyTotal > 0
    }

    // 当前周期剩余百分比
    var currentIntervalPercentageRemaining: Double {
        guard currentIntervalTotal > 0 else { return 0 }
        return (Double(currentIntervalRemaining) / Double(currentIntervalTotal)) * 100
    }

    // 当前周期已用百分比
    var currentIntervalPercentageUsed: Double {
        guard currentIntervalTotal > 0 else { return 0 }
        return (Double(currentIntervalUsedCount) / Double(currentIntervalTotal)) * 100
    }

    var currentIntervalDuration: TimeInterval? {
        guard let startTime, let endTime else { return nil }
        return endTime.timeIntervalSince(startTime)
    }

    var isShortCurrentInterval: Bool {
        guard let currentIntervalDuration else { return false }
        return currentIntervalDuration < 86_400
    }

    // 周是否满的（已用为0 = 没用过）
    var isWeeklyFull: Bool {
        hasWeeklyLimit && weeklyUsedCount == 0
    }

    // 格式化重置时间文本
    // 如果周期不足24小时（如M*的4小时），显示完整周期 "04/08 20:00-00:00"
    // 如果周期是完整的24小时（如其他模型的00:00-00:00），只显示截止时间 "04/09 00:00"
    var resetTimeText: String {
        guard let start = startTime, let end = endTime else { return "—" }

        let interval = end.timeIntervalSince(start)
        let isFullDay = interval >= 86400  // 24小时 = 86400秒

        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM/dd"
        let startDay = formatter.string(from: start)
        let endDay = formatter.string(from: end)

        if !isFullDay {
            // 不足24小时，显示完整周期
            formatter.dateFormat = "HH:mm"
            let startStr = formatter.string(from: start)
            let endStr = formatter.string(from: end)

            // 如果起止月日相同，省略截止时间的月日
            if startDay == endDay {
                return "\(startDay) \(startStr)-\(endStr)"
            }
            return "\(startDay) \(startStr)-\(endDay) \(endStr)"
        }

        // 完整24小时，只显示截止时间
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter.string(from: end)
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
    let remainsTime: Int64
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
        case remainsTime = "remains_time"
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

struct GLMQuotaLimitResponse: Decodable {
    let code: Int
    let msg: String?
    let data: GLMQuotaLimitData?
    let success: Bool
}

struct GLMQuotaLimitData: Decodable {
    let limits: [GLMUsageLimitItem]
}

struct GLMUsageLimitItem: Decodable {
    let type: String
    let currentValue: Double
    let usage: Double
    let percentage: Double?
    let nextResetTime: Int64?

    enum CodingKeys: String, CodingKey {
        case type
        case currentValue
        case usage
        case percentage
        case nextResetTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeFlexibleString(forKey: .type)
        currentValue = try container.decodeFlexibleDouble(forKey: .currentValue)
        usage = try container.decodeFlexibleDouble(forKey: .usage)
        percentage = try container.decodeFlexibleOptionalDouble(forKey: .percentage)
        nextResetTime = try container.decodeFlexibleOptionalInt64(forKey: .nextResetTime)
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

private extension KeyedDecodingContainer {
    func decodeFlexibleString(forKey key: Key) throws -> String {
        if let string = try? decode(String.self, forKey: key) {
            return string
        }
        if let int = try? decode(Int.self, forKey: key) {
            return String(int)
        }
        if let double = try? decode(Double.self, forKey: key) {
            return String(double)
        }
        return ""
    }

    func decodeFlexibleDouble(forKey key: Key) throws -> Double {
        if let double = try? decode(Double.self, forKey: key) {
            return double
        }
        if let int = try? decode(Int.self, forKey: key) {
            return Double(int)
        }
        if let string = try? decode(String.self, forKey: key),
           let double = Double(string) {
            return double
        }
        return 0
    }

    func decodeFlexibleOptionalDouble(forKey key: Key) throws -> Double? {
        guard contains(key) else { return nil }
        return try decodeFlexibleDouble(forKey: key)
    }

    func decodeFlexibleOptionalInt64(forKey key: Key) throws -> Int64? {
        guard contains(key) else { return nil }
        if let int = try? decode(Int64.self, forKey: key) {
            return int
        }
        if let double = try? decode(Double.self, forKey: key) {
            return Int64(double)
        }
        if let string = try? decode(String.self, forKey: key),
           let int = Int64(string) {
            return int
        }
        return nil
    }
}

extension ModelUsageData {
    var isFullQuotaUnused: Bool {
        currentIntervalTotal > 0 &&
            currentIntervalRemaining >= currentIntervalTotal &&
            currentIntervalUsedCount == 0
    }

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
