import Foundation

struct QuotaChartTimeTick: Equatable {
    let ratio: Double
    let label: String
}

enum QuotaChartTimeTickBuilder {
    static func ticks(startTime: Date?, endTime: Date?) -> [QuotaChartTimeTick] {
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
            return ticks(
                duration: duration,
                unitDuration: 86_400,
                suffix: "d")
        }
        return []
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
