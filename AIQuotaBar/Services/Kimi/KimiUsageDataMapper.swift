import CodexBarCore
import Foundation

enum KimiUsageDataMapper {
    static func map(
        _ snapshot: UsageSnapshot,
        source: String,
        accountName: String? = nil,
        now: Date = Date()
    ) throws -> UsageData {
        var models: [ModelUsageData] = []

        if let session = snapshot.secondary {
            let name = session.windowMinutes.map {
                $0 % 60 == 0 ? "\($0 / 60)h" : "\($0)m"
            } ?? "Rate limit"
            models.append(model(from: session, name: name, source: source, now: now,
                                sampledAt: snapshot.updatedAt))
        }
        if let weekly = snapshot.primary {
            models.append(model(from: weekly, name: "7d", source: source, now: now,
                                sampledAt: snapshot.updatedAt))
        }

        for extra in snapshot.extraRateWindows ?? [] {
            let name = extra.id == "kimi-monthly" ? "Total usage" : extra.title
            models.append(model(from: extra.window, name: name, source: source, now: now,
                                sampledAt: snapshot.updatedAt,
                                inferStart: extra.id != "kimi-monthly"))
        }
        if let accountName { models = models.map { $0.withAccountName(accountName) } }

        guard !models.isEmpty else {
            throw UsageError.invalidResponse
        }

        return UsageData(
            provider: .kimi,
            remains: models.filter(\.isCurrentIntervalAvailable).count,
            total: models.count,
            timestamp: snapshot.updatedAt,
            models: models,
            subscribeTitle: nil,
            subscribeEndTime: nil)
    }

    private static func model(
        from window: RateWindow,
        name: String,
        source: String,
        now: Date,
        sampledAt: Date,
        inferStart: Bool = true
    ) -> ModelUsageData {
        let remaining = min(100, max(0, Int(window.remainingPercent.rounded())))
        let startTime = window.windowMinutes.map { minutes in
            inferStart && minutes > 0 ? window.resetsAt?.addingTimeInterval(-Double(minutes) * 60) : nil
        } ?? nil
        let remainsTime = window.resetsAt.map {
            max(0, Int($0.timeIntervalSince(now) * 1_000))
        } ?? 0

        return ModelUsageData(
            provider: .kimi,
            accountName: nil,
            modelName: name,
            currentIntervalTotal: 100,
            currentIntervalUsed: remaining,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: remainsTime,
            startTime: startTime,
            endTime: window.resetsAt,
            weeklyStartTime: nil,
            weeklyEndTime: nil,
            valueSuffix: "%",
            detailText: source,
            currentIntervalRemainingPercent: remaining,
            weeklyRemainingPercent: nil,
            progressBarPercentOverride: nil,
            progressBarRightText: nil,
            // 抓取时刻，不是窗口边界。这一列决定「本机还是云端更新」时选哪一行,
            // 缺了它就只能永远本机优先。`now` 是算剩余时间用的当前时刻，两者
            // 语义不同,不要混用。
            sampledAt: sampledAt)
    }
}
