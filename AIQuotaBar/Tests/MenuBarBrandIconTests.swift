import AppKit
import XCTest
@testable import AIQuotaBar

final class MenuBarBrandIconTests: XCTestCase {
    func test_codex_returnsRasterizedImage() {
        let image = MenuBarBrandIcon.image(for: .codex)
        XCTAssertNotNil(image, "codex provider should have a brand icon")
        XCTAssertEqual(image?.size, NSSize(width: 16, height: 16))
        XCTAssertTrue(image?.isTemplate ?? false, "should be a template image for dark/light mode")
        // 强制光栅化：要求 image 立刻产生像素数据，pixelWidth 必须 > 0，
        // 否则 NSStatusBarButton 绘制时 SVG 路径不会被画出来（看到的就是无意义圆点）。
        let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        XCTAssertNotNil(cgImage, "codex icon should produce a CGImage")
        XCTAssertGreaterThan(cgImage?.width ?? 0, 0, "codex icon should have non-zero pixel width")
    }

    func test_miniMax_returnsRasterizedImage() {
        let image = MenuBarBrandIcon.image(for: .miniMax)
        XCTAssertNotNil(image, "miniMax provider should have a brand icon")
        XCTAssertEqual(image?.size, NSSize(width: 16, height: 16))
        let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        XCTAssertNotNil(cgImage, "miniMax icon should produce a CGImage")
        XCTAssertGreaterThan(cgImage?.width ?? 0, 0, "miniMax icon should have non-zero pixel width")
    }

    func test_glm_returnsNil() {
        // GLM 暂未提供品牌图标
        let image = MenuBarBrandIcon.image(for: .glm)
        XCTAssertNil(image)
    }
}
