import XCTest
@testable import AIQuotaBar

final class QuotaConsumptionForecastTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testFlatLatestIntervalProducesNoImmediateForecast() {
        let samples = [sample(minutes: 0, remaining: 80),
                       sample(minutes: 10, remaining: 80)]

        XCTAssertTrue(forecasts(samples, limit: 1).isEmpty)
    }

    func testOlderConsumptionStillProducesLongerLookbackForecast() throws {
        let samples = [sample(minutes: 0, remaining: 100),
                       sample(minutes: 10, remaining: 80),
                       sample(minutes: 20, remaining: 80)]

        let result = forecasts(samples, limit: 2)
        let forecast = try XCTUnwrap(result.first)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(forecast.lookbackIntervals, 2)
        XCTAssertEqual(forecast.startsAt, samples.last?.timestamp)
        XCTAssertEqual(
            forecast.exhaustsAt.timeIntervalSince(forecast.startsAt),
            4_800,
            accuracy: 0.001)
    }

    func testMultipleLookbacksProduceDifferentForecastSpeeds() {
        let samples = [sample(minutes: 0, remaining: 100),
                       sample(minutes: 10, remaining: 90),
                       sample(minutes: 20, remaining: 60)]

        let result = forecasts(samples, limit: 5)
        XCTAssertEqual(result.map(\.lookbackIntervals), [1, 2])
        XCTAssertGreaterThan(
            result[0].consumptionPerSecond,
            result[1].consumptionPerSecond)
    }

    func testIncreaseStopsForecastBeforeEarlierCycle() {
        let samples = [sample(minutes: 0, remaining: 40),
                       sample(minutes: 10, remaining: 100),
                       sample(minutes: 20, remaining: 80)]

        let result = forecasts(samples, limit: 5)
        XCTAssertEqual(result.map(\.lookbackIntervals), [1])
    }

    func testLookbackIsClampedToFiveIntervals() {
        let samples = (0...7).map {
            sample(minutes: $0 * 10, remaining: 100 - $0 * $0)
        }

        XCTAssertTrue(forecasts(samples, limit: 99).allSatisfy {
            $0.lookbackIntervals <= 5
        })
    }

    func testOldSampleGapStopsForecastFromReachingStalePoints() {
        let samples = [sample(minutes: 0, remaining: 100),
                       sample(minutes: 60, remaining: 80),
                       sample(minutes: 61, remaining: 70)]

        let result = QuotaConsumptionForecaster.forecasts(
            samples: samples,
            isPercentMode: true,
            maximumLookbackIntervals: 5,
            maximumSampleGap: 180)

        XCTAssertEqual(result.map(\.lookbackIntervals), [1])
    }

    private func sample(minutes: Int, remaining: Int) -> ModelQuotaSample {
        ModelQuotaSample(
            timestamp: base.addingTimeInterval(Double(minutes * 60)),
            remaining: remaining,
            percent: remaining)
    }

    private func forecasts(
        _ samples: [ModelQuotaSample],
        limit: Int
    ) -> [QuotaConsumptionForecast] {
        QuotaConsumptionForecaster.forecasts(
            samples: samples,
            isPercentMode: true,
            maximumLookbackIntervals: limit)
    }
}
