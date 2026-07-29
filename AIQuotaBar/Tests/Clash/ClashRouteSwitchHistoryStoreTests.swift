import Foundation
import XCTest
@testable import AIQuotaBar

final class ClashRouteSwitchHistoryStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ClashRouteSwitchHistoryStoreTests.\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testPersistsOnlyThreeMostRecentSwitches() {
        let store = ClashRouteSwitchHistoryStore(
            defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_785_307_200)

        for index in 0..<4 {
            store.recordSwitch(
                from: "Route \(index)",
                to: "Route \(index + 1)",
                at: start.addingTimeInterval(
                    TimeInterval(index)))
        }

        let records = ClashRouteSwitchHistoryStore(
            defaults: defaults).load()

        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(
            records.map(\.toRoute),
            ["Route 4", "Route 3", "Route 2"])
        XCTAssertEqual(
            records.map(\.fromRoute),
            ["Route 3", "Route 2", "Route 1"])
    }

    func testDoesNotRecordNoOpSwitch() {
        let store = ClashRouteSwitchHistoryStore(
            defaults: defaults)

        let records = store.recordSwitch(
            from: "JP 01",
            to: "JP 01")

        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(store.load().isEmpty)
    }
}
