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
            return hourBoundaryTicks(
                startTime: startTime,
                endTime: endTime,
                calendar: calendar)
        }
        if duration <= 8 * 86_400 {
            return midnightTicks(
                startTime: startTime,
                endTime: endTime,
                calendar: calendar)
        }
        return []
    }

    /// 单日窗口按本地自然整点画线：每个落在 (start, end) 区间内的整点一条，
    /// 与多日窗口的 0:00 日界线同一规范。label 未被使用（hover 标签见
    /// `fullHourTicks`），保留占位。
    static func hourBoundaryTicks(
        startTime: Date,
        endTime: Date,
        calendar: Calendar = .current
    ) -> [QuotaChartTimeTick] {
        let duration = endTime.timeIntervalSince(startTime)
        guard duration > 0 else { return [] }
        guard let firstHour = calendar.dateInterval(of: .hour, for: startTime)?.start else { return [] }

        var ticks: [QuotaChartTimeTick] = []
        var hour = firstHour
        while hour <= endTime {
            if hour > startTime {
                ticks.append(QuotaChartTimeTick(
                    ratio: hour.timeIntervalSince(startTime) / duration,
                    label: ""))
            }
            guard let next = calendar.date(byAdding: .hour, value: 1, to: hour) else { break }
            hour = next
        }
        return ticks
    }

    /// 完整落在 [start, end] 内的自然小时，在其半点位置给出 `3PM` 式标签：
    /// 只有完整一小时都在窗口里的时段才配标签，居中显示在该小时中间点，
    /// 与 `fullDayTicks` 同一规范。
    static func fullHourTicks(
        startTime: Date,
        endTime: Date,
        calendar: Calendar = .current
    ) -> [QuotaChartTimeTick] {
        let duration = endTime.timeIntervalSince(startTime)
        guard duration > 0 else { return [] }
        guard let firstHour = calendar.dateInterval(of: .hour, for: startTime)?.start else { return [] }

        let formatter = DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "ha"

        var ticks: [QuotaChartTimeTick] = []
        var hourStart = firstHour
        while hourStart <= endTime {
            guard let hourEnd = calendar.date(byAdding: .hour, value: 1, to: hourStart) else { break }
            if hourStart >= startTime, hourEnd <= endTime {
                let midpoint = hourStart.addingTimeInterval(hourEnd.timeIntervalSince(hourStart) / 2)
                ticks.append(QuotaChartTimeTick(
                    ratio: midpoint.timeIntervalSince(startTime) / duration,
                    label: formatter.string(from: hourStart)))
            }
            hourStart = hourEnd
        }
        return ticks
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

    /// 完整落在 [start, end] 内的自然日，在其正午位置给出 `MM/dd` 标签：
    /// 只有一整天都在窗口里的日子才配标签，居中显示在当天中间点。
    static func fullDayTicks(
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
        var dayStart = calendar.startOfDay(for: startTime)
        while dayStart <= endTime {
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            if dayStart >= startTime, dayEnd <= endTime {
                let midpoint = dayStart.addingTimeInterval(dayEnd.timeIntervalSince(dayStart) / 2)
                ticks.append(QuotaChartTimeTick(
                    ratio: midpoint.timeIntervalSince(startTime) / duration,
                    label: formatter.string(from: dayStart)))
            }
            dayStart = dayEnd
        }
        return ticks
    }
}
