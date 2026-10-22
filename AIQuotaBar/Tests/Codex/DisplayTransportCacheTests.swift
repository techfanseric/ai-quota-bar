import Foundation
import XCTest
@testable import AIQuotaBar

final class DisplayTransportCacheTests: XCTestCase {
    func testHungServiceTimesOutWithoutBlockingOtherDisplayOrOpeningDuplicates() {
        let cache = DisplayTransportCache<String, NSObject>(timeout: 0.02)
        let gate = DispatchSemaphore(value: 0)
        let opened = expectation(description: "late open finished")
        let expected = NSObject()
        let start = Date()
        XCTAssertNil(cache.resolve("unresponsive") {
            _ = gate.wait(timeout: .now() + 2)
            opened.fulfill()
            return expected
        })
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3)
        cache.invalidate("unresponsive")
        XCTAssertNil(cache.resolve("unresponsive") { XCTFail("duplicate pending open"); return nil })
        let healthy = NSObject()
        XCTAssertTrue(cache.resolve("healthy") { healthy } === healthy)
        gate.signal()
        wait(for: [opened], timeout: 1)
        XCTAssertTrue(cache.resolve("unresponsive") { XCTFail("cached service reopened"); return nil } === expected)
    }

    func testFailedOpenIsBackedOffAndSuccessfulOpenIsReused() {
        let cache = DisplayTransportCache<String, NSObject>(timeout: 0.05)
        XCTAssertNil(cache.resolve("failed") { nil })
        XCTAssertNil(cache.resolve("failed") { XCTFail("failure cooldown ignored"); return nil })
        let expected = NSObject()
        XCTAssertTrue(cache.resolve("healthy") { expected } === expected)
        XCTAssertTrue(cache.resolve("healthy") { XCTFail("unnecessary reopen"); return nil } === expected)
    }
}
