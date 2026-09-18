import AppKit
import XCTest
@testable import AIQuotaBar

final class ProviderLogoTests: XCTestCase {
    func testEveryProviderHasBundledSVGLogo() {
        for provider in UsageProvider.allCases {
            let image = ProviderLogo.image(for: provider)
            XCTAssertNotNil(image, "\(provider.rawValue) 缺少打包的 SVG logo")
            XCTAssertGreaterThan(image?.size.width ?? 0, 0, provider.rawValue)
            XCTAssertGreaterThan(image?.size.height ?? 0, 0, provider.rawValue)
        }
    }

    func testLogoImageIsCachedAcrossCalls() {
        XCTAssertTrue(ProviderLogo.image(for: .codex) === ProviderLogo.image(for: .codex))
    }

    func testMonochromeLogosUseDarkVariants() {
        XCTAssertTrue(ProviderLogo.isMonochrome(assetName: ProviderLogo.assetName(for: .codex)))
        XCTAssertTrue(ProviderLogo.isMonochrome(assetName: ProviderLogo.assetName(for: .glm)))
        XCTAssertFalse(ProviderLogo.isMonochrome(assetName: ProviderLogo.assetName(for: .miniMax)))
        XCTAssertFalse(ProviderLogo.isMonochrome(assetName: ProviderLogo.assetName(for: .kimi)))
    }
}
