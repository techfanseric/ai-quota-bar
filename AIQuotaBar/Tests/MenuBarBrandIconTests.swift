import XCTest
@testable import AIQuotaBar

final class MenuBarBrandIconTests: XCTestCase {
    func testLegacyBrandIconPathStaysDisabledForCustomStatusBarViews() {
        for provider in [UsageProvider.codex, .miniMax, .glm] {
            XCTAssertNil(MenuBarBrandIcon.image(for: provider))
        }
    }
}
