import XCTest
@testable import AIQuotaBar

final class PlaceholderTests: XCTestCase {
    func test_testsTargetLinksBusinessModule() {
        XCTAssertEqual(UsageProvider.allCases.count, 3)
    }
}
