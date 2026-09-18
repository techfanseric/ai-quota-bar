import XCTest
@testable import CodexLocalUsageCore

final class UsageHistoryTests: XCTestCase {
    func testLocalMidnightBoundariesZerosFutureAndWeightedCache() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = UsageTime.parse("2026-09-18T04:00:00Z")!
        func e(_ time: String, _ input: Int64, _ cache: Int64) -> LocalUsageEvent {
            LocalUsageEvent(id: time, occurredAt: UsageTime.string(UsageTime.parse(time)!), model: "test", tokens: UsageTokens(input: input, cached: cache))
        }
        let events = [e("2026-09-16T15:59:59Z", 900, 0), e("2026-09-16T16:00:00Z", 100, 100),
                      e("2026-09-17T15:59:59Z", 900, 0), e("2026-09-17T16:00:00Z", 200, 100), e("2026-09-18T05:00:00Z", 999, 0)]
        let result = UsageHistory.buckets(events: events, prices: [], days: 3, now: now, calendar: calendar)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map { $0.summary.tokens.input }, [900, 1000, 200])
        XCTAssertEqual(result[1].summary.cacheHitRate!, 0.1, accuracy: 0.0001)
        XCTAssertEqual(result[2].summary.pricedRecords, 0)
        let hourly = UsageHistory.buckets(events: events, prices: [], days: 1, now: now, calendar: calendar)
        XCTAssertEqual(hourly.count, 13)
        XCTAssertEqual(hourly[0].summary.records, 1)
        XCTAssertEqual(hourly[1].summary.records, 0)
        XCTAssertNil(hourly[1].summary.cacheHitRate)
    }
    func testDSTDayHas23HourlyBucketsAndVersionedPrices() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = UsageTime.parse("2026-03-09T06:59:59Z")!
        let event = LocalUsageEvent(id: "e", occurredAt: "2026-03-08T10:00:00.000Z", model: "test", tokens: UsageTokens(input: 1_000_000))
        let prices = [UsagePrice(model: "test", version: "v1", source: "test", effectiveFrom: "2026-03-08T00:00:00Z", input: 2, cached: 1, output: 3)]
        let result = UsageHistory.buckets(events: [event], prices: prices, days: 1, now: now, calendar: calendar)
        XCTAssertEqual(result.count, 23)
        XCTAssertEqual(result.reduce(Decimal(0)) { $0 + $1.summary.cost }, 2)
        XCTAssertEqual(result.reduce(0) { $0 + $1.summary.records }, 1)
    }
}

extension UsageHistoryTests {
    func testNaturalMonthLengthsAndExcludesOtherMonthsAndFuture() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        for (date, count) in [("2025-02-14T04:00:00Z",28), ("2024-02-14T04:00:00Z",29), ("2026-04-14T04:00:00Z",30), ("2026-05-14T04:00:00Z",31)] {
            let now = UsageTime.parse(date)!
            XCTAssertEqual(UsageHistory.month(events: [], prices: [], now: now, calendar: calendar).count, count)
        }
        let now = UsageTime.parse("2026-09-18T04:00:00Z")!
        let times = ["2026-08-31T15:59:59Z", "2026-08-31T16:00:00Z", "2026-09-18T03:59:59Z", "2026-09-19T00:00:00Z"]
        let events = times.map { LocalUsageEvent(id: $0, occurredAt: UsageTime.string(UsageTime.parse($0)!), model: "m", tokens: UsageTokens(input: 10)) }
        let month = UsageHistory.month(events: events, prices: [], now: now, calendar: calendar)
        XCTAssertEqual(month.count, 30)
        XCTAssertEqual(month[0].summary.records, 1)
        XCTAssertEqual(month[17].summary.records, 1)
        XCTAssertTrue(month.dropFirst(18).allSatisfy { $0.summary.records == 0 })
        XCTAssertEqual(month.reduce(0) { $0 + $1.summary.records }, 2)
    }
    func testRolling24HoursHas288NonOverlappingFiveMinuteSegments() {
        // A spring DST transition and a month boundary do not change elapsed duration.
        for text in ["2026-03-09T07:15:00Z", "2026-11-02T08:15:00Z", "2026-10-01T00:05:00Z"] {
            let now = UsageTime.parse(text)!, start = now.addingTimeInterval(-86400)
            let timestamps = [-1.0, 0, 299.999, 300, 86399, 86400, 86401]
            let events = timestamps.enumerated().map { i, offset in
                LocalUsageEvent(id: "e\(i)", occurredAt: UsageTime.string(start.addingTimeInterval(offset)), model: "m", tokens: UsageTokens(input: 100, cached: 20))
            }
            let rows = UsageHistory.last24Hours(events: events, prices: [], now: now)
            XCTAssertEqual(rows.count, 288)
            XCTAssertEqual(rows.first?.start, start)
            XCTAssertEqual(rows.last?.end, now)
            XCTAssertTrue(rows.allSatisfy { $0.end.timeIntervalSince($0.start) == 300 })
            XCTAssertEqual(rows[0].summary.records, 2)
            XCTAssertEqual(rows[1].summary.records, 1)
            XCTAssertEqual(rows[287].summary.records, 1)
            XCTAssertEqual(rows.reduce(0) { $0 + $1.summary.records }, 4)
            XCTAssertEqual(rows[0].summary.cacheHitRate!, 0.2, accuracy: 0.0001)
            XCTAssertNil(rows[2].summary.cacheHitRate)
        }
    }
}
