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
            weeklyRemainingPercent: nil,
            progressBarPercentOverride: nil,
            progressBarRightText: nil)
    }

    /// codexbar 用 1000 作为 credits 进度条的固定满刻度，
    /// 渲染时按 `percent = (creditsRemaining / 1000) * 100` 计算。
    /// 这里沿用同一全刻度，并通过 `progressBarPercentOverride`
    /// 走"剩余比例"渲染（与默认"已用比例"方向相反），保证满额度时显示完整条。
    private static let creditsFullScale: Double = 1000

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
        let percentLeft = min(100, max(0, (remaining / creditsFullScale) * 100))
        let scaleText = "\(UsageFormatter.tokenCountString(Int(creditsFullScale))) tokens"

        return ModelUsageData(
            provider: .codex,
            accountName: accountName,
            modelName: "Credits",
            currentIntervalTotal: Int(creditsFullScale),
            currentIntervalUsed: intRemaining,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: 0,
            startTime: nil,
            endTime: nil,
            weeklyStartTime: nil,
            weeklyEndTime: nil,
            valueSuffix: " left",
            detailText: detail,
            currentIntervalRemainingPercent: nil,
            weeklyRemainingPercent: nil,
            progressBarPercentOverride: percentLeft,
            progressBarRightText: scaleText)
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
            weeklyRemainingPercent: nil,
            progressBarPercentOverride: nil,
            progressBarRightText: nil)
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
            parts.append(prettySourceLabel(sourceLabel))
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

    /// 把 codexbar 的小写 source 标签（oauth / codex-cli / openai-web）
    /// 映射成菜单可读形式（OAuth / Codex CLI / OpenAI Web）。
    private static func prettySourceLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "oauth": return "OAuth"
        case "cli", "codex-cli": return "Codex CLI"
        case "web", "openai-web": return "OpenAI Web"
        default: return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }
}
