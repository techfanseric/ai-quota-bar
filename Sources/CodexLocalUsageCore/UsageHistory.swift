import Foundation

public struct UsageHistoryBucket: Identifiable, Sendable {
    public var id: Date { start }
    public let start: Date
    public let end: Date
    public let summary: UsageSummary
}

/// Calendar boundaries preserve local days, including 23/25-hour DST days.
/// Empty elapsed buckets are zero usage; missing prices/rates remain nil in the UI.
public enum UsageHistory {
    public static func buckets(events: [LocalUsageEvent], prices: [UsagePrice], days: Int,
                               now: Date = Date(), calendar: Calendar = .current) -> [UsageHistoryBucket] {
        let dayCount = max(1, min(days, 365))
        let start = calendar.date(byAdding: .day, value: -(dayCount - 1), to: calendar.startOfDay(for: now))!
        let component: Calendar.Component = dayCount == 1 ? .hour : .day
        var bounds: [(Date, Date)] = []
        var cursor = start
        while cursor <= now {
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor), next > cursor else { break }
            bounds.append((cursor, next)); cursor = next
        }
        let keys = bounds.map { UsageTime.string($0.0) }
        let upper = UsageTime.string(now.addingTimeInterval(0.001))
        var grouped = Array(repeating: [LocalUsageEvent](), count: bounds.count)
        // O(events log buckets), no repeated full-history scans or per-event date parsing.
        for event in events {
            guard let first = keys.first, event.occurredAt >= first, event.occurredAt < upper else { continue }
            var lo = 0, hi = keys.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if keys[mid] <= event.occurredAt { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { grouped[lo - 1].append(event) }
        }
        return bounds.enumerated().map { index, interval in
            UsageHistoryBucket(start: interval.0, end: interval.1,
                               summary: UsageSummary(events: grouped[index], prices: prices))
        }
    }
}

public extension UsageHistory {
    /// Full natural month; future cells remain in the calendar but contain no events.
    static func month(events: [LocalUsageEvent], prices: [UsagePrice], now: Date = Date(),
                      calendar: Calendar = .current) -> [UsageHistoryBucket] {
        guard let month = calendar.dateInterval(of: .month, for: now) else { return [] }
        var bounds: [(Date, Date)] = []
        var cursor = month.start
        while cursor < month.end {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
            bounds.append((cursor, min(next, month.end)))
            cursor = next
        }
        return aggregate(events: events, prices: prices, bounds: bounds, through: now)
    }

    /// Exactly 24 elapsed hours, including across DST and month boundaries.
    /// Each consecutive group of twelve cells is one hour; no partial/future hour is padded in.
    static func last24Hours(events: [LocalUsageEvent], prices: [UsagePrice], now: Date = Date()) -> [UsageHistoryBucket] {
        let start = now.addingTimeInterval(-24 * 3600)
        let bounds = (0..<288).map { index in
            (start.addingTimeInterval(Double(index) * 300), start.addingTimeInterval(Double(index + 1) * 300))
        }
        return aggregate(events: events, prices: prices, bounds: bounds, through: now)
    }

    private static func aggregate(events: [LocalUsageEvent], prices: [UsagePrice],
                                  bounds: [(Date, Date)], through now: Date) -> [UsageHistoryBucket] {
        let keys = bounds.map { UsageTime.string($0.0) }
        guard let first = keys.first, let last = bounds.last else { return [] }
        let upper = UsageTime.string(min(now, last.1))
        var grouped = Array(repeating: [LocalUsageEvent](), count: bounds.count)
        for event in events {
            guard event.occurredAt >= first, event.occurredAt < upper else { continue }
            var lo = 0, hi = keys.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if keys[mid] <= event.occurredAt { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { grouped[lo - 1].append(event) }
        }
        return bounds.enumerated().map { i, range in
            UsageHistoryBucket(start: range.0, end: range.1, summary: UsageSummary(events: grouped[i], prices: prices))
        }
    }
}
