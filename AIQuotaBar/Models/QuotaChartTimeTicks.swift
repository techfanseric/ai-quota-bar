import Foundation

struct QuotaChartTimeTick: Equatable {
    let ratio: Double
    let label: String
}

enum QuotaChartTimeTickBuilder {
    static func ticks(
        startTime: Date?,
        endTime: Date?,
        calendar: Calendar = .current
    ) -> [QuotaChartTimeTick] {
        guard let startTime, let endTime else { return [] }
        let duration = endTime.timeIntervalSince(startTime)
        guard duration > 0 else { return [] }

        if duration <= 24 * 3_600 {
            return ticks(
                duration: duration,
                unitDuration: 3_600,
                suffix: "h")
        }
        if duration <= 8 * 86_400 {
            return midnightTicks(
                startTime: startTime,
                endTime: endTime,
                calendar: calendar)
        }
        return []
    }

    /// 多日窗口按本地 0:00 画日界线：每个落在 (start, end) 区间内的午夜一条，
    /// label 用 `MM/dd`，一眼看出是哪一天。
    static func midnightTicks(
        startTime: Date,
        endTime: Date,
        calendar: Calendar = .current
    ) -> [QuotaChartTimeTick] {
        let duration = endTime.timeIntervalSince(startTime)
        guard duration > 0 else { return [] }

        let formatter = DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.locale = .current
        formatter.dateFormat = "MM/dd"

        var ticks: [QuotaChartTimeTick] = []
        var day = calendar.startOfDay(for: startTime)
        while day <= endTime {
            if day > startTime {
                ticks.append(QuotaChartTimeTick(
                    ratio: day.timeIntervalSince(startTime) / duration,
                    label: formatter.string(from: day)))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return ticks
    }

    private static func ticks(
        duration: TimeInterval,
        unitDuration: TimeInterval,
        suffix: String
    ) -> [QuotaChartTimeTick] {
        let totalUnits = duration / unitDuration
        guard totalUnits >= 2 else { return [] }
        let interiorUnitCount = max(0, Int(ceil(totalUnits - 0.000_000_1)) - 1)
        guard interiorUnitCount > 0 else { return [] }
        return (1 ... interiorUnitCount).map { unit in
            QuotaChartTimeTick(
                ratio: Double(unit) * unitDuration / duration,
                label: "\(unit)\(suffix)")
        }
    }
}
