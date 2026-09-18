import Foundation
import XCTest
@testable import AIQuotaBar

@MainActor
final class AnalyticsScheduleTests: XCTestCase {
    func testOptInIsOffByDefaultAndDisabledUsageCreatesNoIdentifier() throws {
        let name = "AnalyticsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppUsageAnalytics(defaults: defaults)
        XCTAssertFalse(model.enabled)
        model.start(); model.recordActivity()
        XCTAssertNil(defaults.string(forKey: "anonymousAnalytics.token"))
    }
    func testUTCDayRolloverCountsActivityDespiteRecentPreviousDayUse() {
        let previous = ISO8601DateFormatter().date(from: "2026-09-18T23:59:00Z")!
        let now = previous.addingTimeInterval(120)
        XCTAssertTrue(AnalyticsSchedule.isDue(active: true, now: now, lastActive: previous, lastPulse: previous))
    }
    func testBackgroundHeartbeatDoesNotSuppressFirstInteraction() {
        let now = Date()
        XCTAssertTrue(AnalyticsSchedule.isDue(active: true, now: now, lastActive: nil, lastPulse: now))
        XCTAssertFalse(AnalyticsSchedule.isDue(active: false, now: now, lastActive: nil, lastPulse: now))
        XCTAssertTrue(AnalyticsSchedule.isDue(active: false, now: now.addingTimeInterval(3601), lastActive: now, lastPulse: now))
        XCTAssertFalse(AnalyticsSchedule.isDue(active: true, now: now.addingTimeInterval(60), lastActive: now, lastPulse: now))
    }
}
