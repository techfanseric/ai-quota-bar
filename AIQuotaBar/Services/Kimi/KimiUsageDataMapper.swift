import CodexBarCore
import Foundation

enum KimiUsageDataMapper {
    static func map(
        _ snapshot: UsageSnapshot,
        source: String,
        now: Date = Date()
    ) throws -> UsageData {
        var models: [ModelUsageData] = []

        if let session = snapshot.secondary {
            models.append(model(from: session, name: "5h", source: source, now: now))
        }
        if let weekly = snapshot.primary {
            models.append(model(from: weekly, name: "7d", source: source, now: now))
        }

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
        now: Date
    ) -> ModelUsageData {
        let remaining = min(100, max(0, Int(window.remainingPercent.rounded())))
        let startTime = window.windowMinutes.map { minutes in
            window.resetsAt?.addingTimeInterval(-Double(minutes) * 60)
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
            sampledAt: nil)
    }
}
