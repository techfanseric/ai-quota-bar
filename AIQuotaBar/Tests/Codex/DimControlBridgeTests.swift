import XCTest
@testable import AIQuotaBar

@MainActor
private final class FakeDimController: DimControlling {
    var isActive = false
    var isTransitioning = false
    private(set) var dimCallCount = 0

    func dim() {
        dimCallCount += 1
        isActive = true
    }
}

final class DimControlBridgeTests: XCTestCase {
    @MainActor
    func testRequestDimsAndAcknowledgesSuccess() async {
        let controller = FakeDimController()
        let bridge = DimControlBridge(controllerProvider: { controller })
        let replied = expectation(description: "dim response")
        var result = false

        bridge.handleRequest(requestID: "request-1") { success in
            result = success
            replied.fulfill()
        }

        await fulfillment(of: [replied], timeout: 1)
        XCTAssertTrue(result)
        XCTAssertEqual(controller.dimCallCount, 1)
    }

    @MainActor
    func testAlreadyActiveRequestDoesNotToggleOrRestore() async {
        let controller = FakeDimController()
        controller.isActive = true
        let bridge = DimControlBridge(controllerProvider: { controller })
        let replied = expectation(description: "dim response")
        var result = false

        bridge.handleRequest(requestID: "request-2") { success in
            result = success
            replied.fulfill()
        }

        await fulfillment(of: [replied], timeout: 1)
        XCTAssertTrue(result)
        XCTAssertEqual(controller.dimCallCount, 0)
    }
}
