import XCTest
@testable import AIQuotaBar

final class PlaceholderTests: XCTestCase {
    func test_testsTargetLinksBusinessModule() {
        XCTAssertEqual(UsageProvider.allCases, [.miniMax, .codex])
    }
}
