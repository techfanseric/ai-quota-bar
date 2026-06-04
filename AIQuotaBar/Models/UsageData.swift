import CodexBarCore
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
    /// Optional current Token Plan / subscription title (e.g. "TokenPlanMax").
    /// Only populated for `.miniMax` provider from the combo/cycle endpoint.
    let subscribeTitle: String?
    /// Optional current subscription end date. Only populated for `.miniMax`.
    let subscribeEndTime: Date?

    /// Percentage remaining (0-100)
    var percentageRemaining: Double {
        guard total > 0 else { return 0 }
        return (Double(remains) / Double(total)) * 100
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
    let accountName: String?
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
    let valueSuffix: String?
    let detailText: String?
    /// API 直接返回的当前周期剩余百分比（0-100），为 nil 时回退到按 count 计算
    let currentIntervalRemainingPercent: Int?
    /// API 直接返回的周剩余百分比（0-100），为 nil 时回退到按 count 计算
    let weeklyRemainingPercent: Int?
    /// 覆盖进度条宽度百分比（0-100）。默认按 `currentIntervalPercentageUsed`（已用）计算；
    /// 设置后用于显示"剩余比例"等反向语义（如 codex credits）。
    let progressBarPercentOverride: Double?
    /// 覆盖进度条右侧文本。默认按 `currentIntervalUsageRatioText` 渲染；
    /// 设置后用于显示"1K tokens"等固定刻度信息。
    let progressBarRightText: String?

    var id: String {
        guard let accountName, !accountName.isEmpty else {
            return "\(provider.rawValue):\(modelName)"
        }
        return "\(provider.rawValue):\(accountName):\(modelName)"
    }

    var displayName: String {
        guard let accountName, !accountName.isEmpty else { return modelName }
        return "\(accountName) · \(modelName)"
    }

    // 剩余 = API 返回的 usage_count
    var currentIntervalRemaining: Int {
        currentIntervalUsed
    }

    var currentIntervalRemainingText: String {
        if let percent = currentIntervalRemainingPercent {
            return "\(percent)%"
        }
        return "\(currentIntervalRemaining)\(valueSuffix ?? "")"
    }

    // 已用 = 总量 - 剩余
    var currentIntervalUsedCount: Int {
        max(0, currentIntervalTotal - currentIntervalUsed)
    }

    var currentIntervalUsageRatioText: String {
        if valueSuffix == "%" {
            return "\(currentIntervalRemaining)% left"
        }

        if currentIntervalTotal <= 0, let percent = currentIntervalRemainingPercent {
            return "\(percent)% left"
        }

        return "\(currentIntervalUsedCount)/\(currentIntervalTotal)"
    }

    var isCurrentIntervalAvailable: Bool {
        if let percent = currentIntervalRemainingPercent {
            return percent > 0
        }
        return currentIntervalRemaining > 0
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
        if weeklyRemainingPercent != nil {
            return true
        }
        return weeklyTotal > 0
    }

    /// 周配额是否无限制（API 通过 status=3 或 total=0+percent=100 表达）
    var isWeeklyUnlimited: Bool {
        if provider != .miniMax { return false }
        if let percent = weeklyRemainingPercent, percent >= 100, weeklyTotal <= 0 {
            return true
        }
        return false
    }

    var weeklyRemainingPercentValue: Double? {
        guard let percent = weeklyRemainingPercent else { return nil }
        return Double(percent)
    }

    // 当前周期剩余百分比
    var currentIntervalPercentageRemaining: Double {
        if let percent = currentIntervalRemainingPercent {
            return Double(percent)
        }
        guard currentIntervalTotal > 0 else { return 0 }
        return (Double(currentIntervalRemaining) / Double(currentIntervalTotal)) * 100
    }

    // 当前周期已用百分比
    var currentIntervalPercentageUsed: Double {
        if let percent = currentIntervalRemainingPercent {
            return max(0, 100 - Double(percent))
        }
        guard currentIntervalTotal > 0 else { return 0 }
        return (Double(currentIntervalUsedCount) / Double(currentIntervalTotal)) * 100
    }

    /// 进度条实际宽度百分比：默认按"已用比例"渲染，credits 这类反向语义可走 `progressBarPercentOverride`。
    var currentIntervalBarPercent: Double {
        if let override = progressBarPercentOverride {
            return min(100, max(0, override))
        }
        return currentIntervalPercentageUsed
    }

    /// 进度条右侧文本：默认按 `currentIntervalUsageRatioText`，credits 这类固定刻度信息可走 `progressBarRightText`。
    var currentIntervalBarRightText: String {
        if let override = progressBarRightText, !override.isEmpty {
            return override
        }
        return currentIntervalUsageRatioText
    }

    var currentIntervalDuration: TimeInterval? {
        guard let startTime, let endTime else { return nil }
        return endTime.timeIntervalSince(startTime)
    }

    /// 图表 Y 轴上限：有具体计数用计数，否则退到 0-100 百分比
    var currentIntervalYAxisMax: Double {
        if currentIntervalTotal > 0 {
            return Double(currentIntervalTotal)
        }
        if currentIntervalRemainingPercent != nil {
            return 100
        }
        return 0
    }

    /// 是否处于百分比模式（total=0 但 API 返回了百分比）
    var isCurrentIntervalPercentMode: Bool {
        currentIntervalTotal <= 0 && currentIntervalRemainingPercent != nil
    }

    /// 当前周期已用时长占总时长的比例（0-1）。nil 时表示无法计算
    /// （缺起止时间，或 credits 这类反向语义模式）。
    var currentIntervalElapsedRatio: Double? {
        guard progressBarPercentOverride == nil else { return nil }
        guard let startTime, let endTime else { return nil }
        let duration = endTime.timeIntervalSince(startTime)
        guard duration > 0 else { return nil }
        let elapsed = Date().timeIntervalSince(startTime)
        return min(max(elapsed / duration, 0), 1)
    }

    /// 周已用时长占周总时长的比例（0-1）。nil 时表示无法计算
    var weeklyElapsedRatio: Double? {
        guard let weeklyStartTime, let weeklyEndTime else { return nil }
        let duration = weeklyEndTime.timeIntervalSince(weeklyStartTime)
        guard duration > 0 else { return nil }
        let elapsed = Date().timeIntervalSince(weeklyStartTime)
        return min(max(elapsed / duration, 0), 1)
    }

    /// 周已用百分比（0-100），nil 时表示无法计算
    var weeklyPercentageUsed: Double? {
        if let percent = weeklyRemainingPercent {
            return max(0, 100 - Double(percent))
        }
        guard weeklyTotal > 0 else { return nil }
        return (Double(weeklyUsedCount) / Double(weeklyTotal)) * 100
    }

    /// 匀速消耗情况下"周应有的已用百分比"（0-100）
    var weeklyPaceUsedPercent: Double? {
        guard let ratio = weeklyElapsedRatio else { return nil }
        return ratio * 100
    }

    /// 匀速消耗情况下"当前应有的已用百分比"（0-100）。
    /// 用于 Weekly 柱状图 x 轴的 pace tip 位置。
    var currentIntervalPaceUsedPercent: Double? {
        guard let ratio = currentIntervalElapsedRatio else { return nil }
        return ratio * 100
    }

    /// 匀速消耗情况下"当前应有的剩余值"（与 `currentIntervalYAxisMax` 同量纲）。
    /// 用于 5h 面积图 y 轴的节奏参考线高度。
    var currentIntervalPaceRemaining: Double? {
        guard let ratio = currentIntervalElapsedRatio else { return nil }
        return currentIntervalYAxisMax * (1 - ratio)
    }

    /// 节奏快照：复用 codexbar 的 UsagePace.Stage 算法（|delta|≤2 onTrack, ≤6 slightly, ≤12 ahead/behind, >12 far）
    /// 走 `UsagePace.historical` 走的就是这套 stage 分桶。
    /// nil 时表示无法计算（缺起止时间 / credits 模式 / 刚开始且已有消耗 —— 跟 codexbar 一致）。
    var currentIntervalPace: UsagePace? {
        guard progressBarPercentOverride == nil else { return nil }
        guard let startTime, let endTime else { return nil }
        let duration = endTime.timeIntervalSince(startTime)
        guard duration > 0 else { return nil }
        let elapsed = min(max(Date().timeIntervalSince(startTime), 0), duration)

        // codexbar 的 guard：elapsed == 0 且 actual > 0 时不计算（刚开始时已用 > 0 是脏数据）
        let actual = currentIntervalPercentageUsed
        if elapsed == 0, actual > 0 { return nil }

        let expected = (elapsed / duration) * 100
        return UsagePace.historical(
            expectedUsedPercent: expected,
            actualUsedPercent: actual,
            etaSeconds: nil,
            willLastToReset: actual <= expected,
            runOutProbability: nil)
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
        guard let end = endTime else { return "—" }

        if provider == .codex {
            return codexResetTimeText(end)
        }

        guard let start = startTime else {
            return formattedDateTime(end)
        }

        let interval = end.timeIntervalSince(start)
        let isFullDay = interval >= 86400  // 24小时 = 86400秒

        if !isFullDay {
            // 不足24小时，显示完整周期
            let startDay = formattedDay(start)
            let endDay = formattedDay(end)
            let timeFormatter = formatter
            timeFormatter.dateFormat = "HH:mm"
            let startStr = timeFormatter.string(from: start)
            let endStr = timeFormatter.string(from: end)

            // 如果起止月日相同，省略截止时间的月日
            if startDay == endDay {
                return "\(startDay) \(startStr)-\(endStr)"
            }
            return "\(startDay) \(startStr)-\(endDay) \(endStr)"
        }

        // 完整24小时，只显示截止时间
        return formattedDateTime(end)
    }

    private func codexResetTimeText(_ end: Date) -> String {
        let formatter = formatter
        let loweredName = modelName.lowercased()
        let remaining = end.timeIntervalSince(Date())

        if loweredName.contains("5h") ||
            loweredName.contains("short") ||
            loweredName.contains("hour") ||
            remaining < 86_400 {
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: end)
        }

        formatter.dateFormat = "MM/dd"
        return formatter.string(from: end)
    }

    private var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }

    private func formattedDay(_ date: Date) -> String {
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInTomorrow(date) {
            return "Tomorrow"
        }

        let formatter = formatter
        formatter.dateFormat = "MM/dd"
        return formatter.string(from: date)
    }

    private func formattedDateTime(_ date: Date) -> String {
        let formatter = formatter
        formatter.dateFormat = "HH:mm"
        let timeText = formatter.string(from: date)
        return "\(formattedDay(date)) \(timeText)"
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
    let weeklyRemainsTime: Int64?
    let currentIntervalStatus: Int?
    let currentIntervalRemainingPercent: Int?
    let currentWeeklyStatus: Int?
    let currentWeeklyRemainingPercent: Int?
    let intervalBoostPermille: Int?
    let weeklyBoostPermille: Int?

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
        case weeklyRemainsTime = "weekly_remains_time"
        case currentIntervalStatus = "current_interval_status"
        case currentIntervalRemainingPercent = "current_interval_remaining_percent"
        case currentWeeklyStatus = "current_weekly_status"
        case currentWeeklyRemainingPercent = "current_weekly_remaining_percent"
        case intervalBoostPermille = "interval_boost_permille"
        case weeklyBoostPermille = "weekly_boost_permille"
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

/// API response model for MiniMax current subscription / plan metadata.
/// Endpoint: GET https://www.minimaxi.com/v1/api/openplatform/charge/combo/cycle_audio_resource_package?biz_line=2&cycle_type=3&resource_package_type=7
struct MiniMaxCurrentSubscribe: Decodable {
    let currentSubscribeTitle: String?
    /// Milliseconds since 1970-01-01 (UTC). `0` when no active subscription.
    let currentSubscribeEndTimeTs: Int64?
    let currentSubscribeComboId: String?
    let currentSubscribeComboType: Int?
    let currentSubscribeCycleType: Int?
    let renewalState: Int?
    let refundable: Bool?

    enum CodingKeys: String, CodingKey {
        case currentSubscribeTitle = "current_subscribe_title"
        case currentSubscribeEndTimeTs = "current_subscribe_end_time_ts"
        case currentSubscribeComboId = "curr_subscribe_combo_id"
        case currentSubscribeComboType = "current_subscribe_combo_type"
        case currentSubscribeCycleType = "current_subscribe_cycle_type"
        case renewalState = "renewal_state"
        case refundable = "refundable"
    }
}

struct MiniMaxCycleComboResponse: Decodable {
    let currentSubscribe: MiniMaxCurrentSubscribe?

    enum CodingKeys: String, CodingKey {
        case currentSubscribe = "current_subscribe"
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
    let remaining: Double?
    let unit: Int?
    let number: Int?
    let usageDetails: [GLMUsageDetailItem]

    enum CodingKeys: String, CodingKey {
        case type
        case currentValue
        case usage
        case percentage
        case nextResetTime
        case remaining
        case unit
        case number
        case usageDetails
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeFlexibleString(forKey: .type)
        currentValue = try container.decodeFlexibleDouble(forKey: .currentValue)
        usage = try container.decodeFlexibleDouble(forKey: .usage)
        percentage = try container.decodeFlexibleOptionalDouble(forKey: .percentage)
        nextResetTime = try container.decodeFlexibleOptionalInt64(forKey: .nextResetTime)
        remaining = try container.decodeFlexibleOptionalDouble(forKey: .remaining)
        unit = try container.decodeFlexibleOptionalInt(forKey: .unit)
        number = try container.decodeFlexibleOptionalInt(forKey: .number)
        usageDetails = (try? container.decode([GLMUsageDetailItem].self, forKey: .usageDetails)) ?? []
    }
}

struct GLMUsageDetailItem: Decodable {
    let modelCode: String
    let usage: Double

    enum CodingKeys: String, CodingKey {
        case modelCode
        case usage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelCode = try container.decodeFlexibleString(forKey: .modelCode)
        usage = try container.decodeFlexibleDouble(forKey: .usage)
    }
}

struct GLMSubscriptionListResponse: Decodable {
    let code: Int
    let data: [GLMSubscriptionItem]?
    let success: Bool
}

struct GLMSubscriptionItem: Decodable {
    let productName: String?
    let valid: String?
    let nextRenewTime: String?
    let inCurrentPeriod: Bool?
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

    func decodeFlexibleOptionalInt(forKey key: Key) throws -> Int? {
        guard contains(key) else { return nil }
        if let int = try? decode(Int.self, forKey: key) {
            return int
        }
        if let double = try? decode(Double.self, forKey: key) {
            return Int(double)
        }
        if let string = try? decode(String.self, forKey: key),
           let int = Int(string) {
            return int
        }
        return nil
    }
}

extension ModelUsageData {
    var isExhaustedCurrentInterval: Bool {
        if let percent = currentIntervalRemainingPercent {
            return percent <= 0
        }
        return currentIntervalTotal > 0 && currentIntervalRemaining <= 0
    }

    /// 把 CodexUsageDataMapper 写入的 detailText（"Pro 20x · OAuth · resets 04/08 00:00"）
    /// 拆成三段供 section header / model 行复用：
    /// - plan: 形如 "Pro 20x"（用 CodexPlanFormatting 生成的展示名，不再带 "Plan " 前缀）
    /// - source: 形如 "OAuth" / "Codex CLI" / "OpenAI Web"
    /// - rest: 其它 model 自身段（典型为 "resets ..."），供 model 行单独显示
    var parsedDetail: (plan: String?, source: String?, rest: String?) {
        guard let detailText, !detailText.isEmpty else { return (nil, nil, nil) }
        let parts = detailText.components(separatedBy: " · ")
        var plan: String?
        var source: String?
        var restParts: [String] = []
        for part in parts where !part.isEmpty {
            if part.hasPrefix("resets ") {
                restParts.append(part)
            } else if Self.looksLikeCodexPlanName(part), plan == nil {
                plan = part
            } else if source == nil {
                source = part
            } else {
                restParts.append(part)
            }
        }
        let rest = restParts.isEmpty ? nil : restParts.joined(separator: " · ")
        return (plan, source, rest)
    }

    /// 判断 detailText 段落是否像 Codex plan 展示名。
    /// 覆盖 CodexPlanFormatting 输出的常见形态：Pro / Pro 20x / Pro 5x / Plus / Team / Enterprise。
    private static func looksLikeCodexPlanName(_ part: String) -> Bool {
        let lower = part.lowercased()
        if lower == "pro" || lower == "plus" || lower == "team" || lower == "enterprise" {
            return true
        }
        if lower.hasPrefix("pro ") || lower.hasPrefix("pro_") || lower.hasPrefix("pro-") {
            return true
        }
        return false
    }

    var isFullQuotaUnused: Bool {
        if let percent = currentIntervalRemainingPercent {
            return percent >= 100
        }
        return currentIntervalTotal > 0 &&
            currentIntervalRemaining >= currentIntervalTotal &&
            currentIntervalUsedCount == 0
    }

    func formattedMenuBarText(language: AppLanguage) -> String {
        let remaining = currentIntervalRemainingText
        let resetText = formatResetTime(endTime: endTime)
        return "\(remaining)/\(resetText)"
    }

    /// 状态栏单行格式：`<初始>:<剩余%> · <对比匀速消耗%> · <重置时间>`
    /// - `paceSource`: paceDelta 走哪个 model 的字段(codex 用 Weekly 算 reserve)
    /// - 剩余%/reset 时间始终用 self(primary,通常是 5h 短周期)
    func formattedStatusBarLine(providerInitial: String, paceSource: ModelUsageData? = nil) -> String {
        let remaining = currentIntervalRemainingText
        let paceDelta = (paceSource ?? self).formattedPaceDelta()
        let resetText = formatResetTime(endTime: endTime)
        return "\(providerInitial):\(remaining) · \(paceDelta) · \(resetText)"
    }

    /// 对比匀速消耗的进度（"省"的方向为正，符合直觉）：
    /// - 正数 = 用得比匀速慢（剩余比应有多 — ahead / 有余量）
    /// - 负数 = 用得比匀速快（剩余比应有少 — behind / 快烧完）
    /// 统一走 currentInterval 字段（codex Weekly model 的 currentInterval 就是周限额）
    private func formattedPaceDelta() -> String {
        guard let paceUsed = currentIntervalPaceUsedPercent else { return "0%" }
        let actualUsed = 100 - currentIntervalPercentageRemaining
        return formatDelta(paceUsed: paceUsed, actualUsed: actualUsed)
    }

    private func formatDelta(paceUsed: Double, actualUsed: Double) -> String {
        // delta = paceUsed - actualUsed
        // 用得慢 (actualUsed < paceUsed) → 正数（ahead / 省）
        // 用得快 (actualUsed > paceUsed) → 负数（behind / 烧）
        let delta = paceUsed - actualUsed
        let rounded = Int(delta.rounded())
        if rounded == 0 { return "0%" }
        return rounded > 0 ? "+\(rounded)%" : "\(rounded)%"
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
        if hours < 24 {
            return String(format: "%.1fh", hours)
        }
        // >= 1 天：用 d 单位，避免 "105.0h" 占太多字符
        let days = hours / 24.0
        return String(format: "%.1fd", days)
    }
}

extension UsagePace.Stage {
    /// 是否"用得比匀速慢"（即 onTrack / behind 系列）。
    /// 跟 codexbar `paceOnTop` 语义对齐：onTrack / behind → true（ahead 颜色 = 绿），
    /// ahead 系列 → false（deficit 颜色 = 红）。
    var isAhead: Bool {
        switch self {
        case .onTrack, .slightlyBehind, .behind, .farBehind:
            return true
        case .slightlyAhead, .ahead, .farAhead:
            return false
        }
    }
}
