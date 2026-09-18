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
