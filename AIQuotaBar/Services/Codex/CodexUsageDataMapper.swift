import CodexBarCore
import Foundation

/// 适配器：把 CodexBarCore 的 `UsageSnapshot`（外加可选 `CreditsSnapshot`）映射为
/// 应用层统一的 `UsageData` / `ModelUsageData`，供状态栏、菜单和图表复用。
enum CodexUsageDataMapper {
    /// 将 Codex 抓取结果转成 UI 可消费的 `UsageData`。
    /// - Parameters:
    ///   - snapshot: CodexBarCore 抓取的主快照（primary/secondary/extras）。
    ///   - credits: 可选的 credits 余额快照（nil 或 unlimited 时跳过）。
    ///   - sourceLabel: 数据来源标签（oauth / codex-cli / web 等），写入 detailText。
    static func mapToUsageData(
        snapshot: UsageSnapshot,
        credits: CreditsSnapshot?,
        sourceLabel: String) -> UsageData
    {
        var models: [ModelUsageData] = []
        let accountName = snapshot.identity?.accountEmail
        let planType = snapshot.identity?.loginMethod

        if let primary = snapshot.primary {
            models.append(makeModel(
                name: "5h",
                window: primary,
                accountName: accountName,
                planType: planType,
                sourceLabel: sourceLabel))
        }

        if let secondary = snapshot.secondary {
            models.append(makeModel(
                name: "Weekly",
                window: secondary,
                accountName: accountName,
                planType: planType,
                sourceLabel: sourceLabel))
        }

        if let extras = snapshot.extraRateWindows {
            for named in extras {
                models.append(makeModel(
                    name: named.title.isEmpty ? named.id : named.title,
                    window: named.window,
                    accountName: accountName,
                    planType: planType,
                    sourceLabel: sourceLabel))
            }
        }

        // 计划原文用了 `!credits.unlimited` 与 `if let remaining = credits.remaining`，
        // 但 `CreditsSnapshot` 实际没有 `unlimited` 字段，`remaining` 是非可选 Double。
        // 这里改为可选绑定 + 直接取值。
        if let credits {
            let remaining = credits.remaining
            models.append(makeCreditsModel(
                remaining: remaining,
                accountName: accountName,
                planType: planType,
                sourceLabel: sourceLabel))
        }

        if models.isEmpty {
            models.append(makeNotConfiguredPlaceholder(
                accountName: accountName,
                planType: planType,
                sourceLabel: sourceLabel))
        }

        let readyCount = models.filter(\.isCurrentIntervalAvailable).count
        let total = max(models.count, 1)

        return UsageData(
            provider: .codex,
            remains: readyCount,
            total: total,
            timestamp: snapshot.updatedAt,
            models: models)
    }

    private static func makeModel(
        name: String,
        window: RateWindow,
        accountName: String?,
        planType: String?,
        sourceLabel: String) -> ModelUsageData
    {
        let remainingPercent = Int((100 - window.usedPercent).rounded())
        let endTime = window.resetsAt
        let startTime = endTime.map { end in
            end.addingTimeInterval(-Double(window.windowMinutes ?? 0) * 60)
        }
        let detail = makeDetailText(
            planType: planType,
            sourceLabel: sourceLabel,
            endTime: endTime)

        return ModelUsageData(
            provider: .codex,
            accountName: accountName,
            modelName: name,
            currentIntervalTotal: 100,
            currentIntervalUsed: remainingPercent,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: endTime.map { Int($0.timeIntervalSince(Date()) * 1000) } ?? 0,
            startTime: startTime,
            endTime: endTime,
            weeklyStartTime: nil,
            weeklyEndTime: nil,
            valueSuffix: "%",
            detailText: detail,
            currentIntervalRemainingPercent: remainingPercent,
            weeklyRemainingPercent: nil)
    }

    private static func makeCreditsModel(
        remaining: Double,
        accountName: String?,
        planType: String?,
        sourceLabel: String) -> ModelUsageData
    {
        let intRemaining = Int(remaining.rounded())
        let detail = makeDetailText(
            planType: planType,
            sourceLabel: sourceLabel,
            endTime: nil)

        // 修复：plan 原文 `currentIntervalUsed: intRemaining > 0 ? 0 : 1` 是错的。
        // `ModelUsageData.currentIntervalUsed` 在 `UsageData.swift:108` 注释里明确承载
        // "剩余" 语义（`currentIntervalRemaining` 直接返回它），这里必须把真实剩余数字填入。
        return ModelUsageData(
            provider: .codex,
            accountName: accountName,
            modelName: "Credits",
            currentIntervalTotal: 1,
            currentIntervalUsed: intRemaining,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: 0,
            startTime: nil,
            endTime: nil,
            weeklyStartTime: nil,
            weeklyEndTime: nil,
            valueSuffix: nil,
            detailText: detail,
            currentIntervalRemainingPercent: nil,
            weeklyRemainingPercent: nil)
    }

    private static func makeNotConfiguredPlaceholder(
        accountName: String?,
        planType: String?,
        sourceLabel: String) -> ModelUsageData
    {
        // 修复：plan 原文用 `detail ?? "Codex not configured..."`，但当传 `sourceLabel`
        // 时 `detail` 不为 nil（会落到 source label），结果 detailText 不含占位文案。
        // 占位分支必须固定显示 "Codex not configured"，所以直接硬编码。
        return ModelUsageData(
            provider: .codex,
            accountName: accountName,
            modelName: "Codex",
            currentIntervalTotal: 1,
            currentIntervalUsed: 1,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: 0,
            startTime: nil,
            endTime: nil,
            weeklyStartTime: nil,
            weeklyEndTime: nil,
            valueSuffix: nil,
            detailText: "Codex not configured — run `codex` to sign in",
            currentIntervalRemainingPercent: 0,
            weeklyRemainingPercent: nil)
    }

    private static func makeDetailText(
        planType: String?,
        sourceLabel: String?,
        endTime: Date?) -> String?
    {
        var parts: [String] = []
        if let planType, !planType.isEmpty {
            let capitalized = planType.prefix(1).uppercased() + planType.dropFirst()
            parts.append("Plan \(capitalized)")
        }
        if let sourceLabel, !sourceLabel.isEmpty {
            parts.append(sourceLabel)
        }
        if let endTime {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = "MM/dd HH:mm"
            parts.append("resets \(formatter.string(from: endTime))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
