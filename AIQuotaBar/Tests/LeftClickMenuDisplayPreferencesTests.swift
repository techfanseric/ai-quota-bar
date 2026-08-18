import XCTest
@testable import AIQuotaBar

final class LeftClickMenuDisplayPreferencesTests: XCTestCase {
    func testDefaultsToShowingEveryAccountAndDimension() {
        let model = makeModel(account: "user@example.com", name: "5h")
        let preferences = LeftClickMenuDisplayPreferences()

        XCTAssertTrue(preferences.isAccountVisible(LeftClickMenuAccountKey(model: model)))
        XCTAssertTrue(preferences.isModelVisible(model))
        XCTAssertFalse(preferences.hasHiddenItems)
    }

    func testCanHideOneDimensionWithoutHidingItsAccount() {
        let fiveHour = makeModel(account: "user@example.com", name: "5h")
        let weekly = makeModel(account: "user@example.com", name: "Weekly")
        var preferences = LeftClickMenuDisplayPreferences()

        preferences.setModelVisible(false, key: fiveHour.mobileDashboardSelectionKey)

        XCTAssertFalse(preferences.isModelVisible(fiveHour))
        XCTAssertTrue(preferences.isModelVisible(weekly))
        XCTAssertTrue(preferences.isAccountVisible(LeftClickMenuAccountKey(model: fiveHour)))
    }

    func testRestoringAccountPreservesDimensionChoices() {
        let fiveHour = makeModel(account: "user@example.com", name: "5h")
        let weekly = makeModel(account: "user@example.com", name: "Weekly")
        let accountKey = LeftClickMenuAccountKey(model: fiveHour)
        var preferences = LeftClickMenuDisplayPreferences()
        preferences.setModelVisible(false, key: weekly.mobileDashboardSelectionKey)

        preferences.setAccountVisible(false, key: accountKey)
        XCTAssertFalse(preferences.isModelVisible(fiveHour))
        XCTAssertFalse(preferences.isModelVisible(weekly))

        preferences.setAccountVisible(true, key: accountKey)
        XCTAssertTrue(preferences.isModelVisible(fiveHour))
        XCTAssertFalse(preferences.isModelVisible(weekly))
    }

    func testRoundTripsThroughUserDefaults() throws {
        let suiteName = "LeftClickMenuDisplayPreferencesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = makeModel(account: "User@Example.com", name: "5h")
        var preferences = LeftClickMenuDisplayPreferences()
        preferences.setModelVisible(false, key: model.mobileDashboardSelectionKey)

        preferences.save(to: defaults)
        let restored = LeftClickMenuDisplayPreferences.load(from: defaults)

        XCTAssertEqual(restored, preferences)
        XCTAssertFalse(restored.isModelVisible(model))
    }

    private func makeModel(account: String?, name: String) -> ModelUsageData {
        ModelUsageData(
            provider: .codex,
            accountName: account,
            modelName: name,
            currentIntervalTotal: 100,
            currentIntervalUsed: 75,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: 0,
            startTime: nil,
            endTime: nil,
            weeklyStartTime: nil,
            weeklyEndTime: nil,
            valueSuffix: "%",
            detailText: nil,
            currentIntervalRemainingPercent: 75,
            weeklyRemainingPercent: nil,
            progressBarPercentOverride: nil,
            progressBarRightText: nil,
            sampledAt: nil)
    }
}
