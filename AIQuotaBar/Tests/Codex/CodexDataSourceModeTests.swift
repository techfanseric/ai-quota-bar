import XCTest
@testable import AIQuotaBar

final class CodexDataSourceModeTests: XCTestCase {
    func testRawValueRoundTrip() {
        for mode in CodexDataSourceMode.allCases {
            let encoded = mode.rawValue
            let decoded = CodexDataSourceMode(rawValue: encoded)
            XCTAssertEqual(decoded, mode, "Round trip failed for \(mode)")
        }
    }

    func testDisplayNamesAreUserFacing() {
        XCTAssertEqual(CodexDataSourceMode.auto.displayName, "Auto")
        XCTAssertEqual(CodexDataSourceMode.oauth.displayName, "OAuth")
        XCTAssertEqual(CodexDataSourceMode.cli.displayName, "CLI")
        XCTAssertEqual(CodexDataSourceMode.web.displayName, "Web dashboard")
    }

    func testStorageKeyIsStable() {
        XCTAssertEqual(CodexDataSourceMode.storageKey, "codexSourceMode")
    }

    func testMapsToProviderSourceMode() {
        XCTAssertEqual(CodexDataSourceMode.auto.codexbarSourceMode, .auto)
        XCTAssertEqual(CodexDataSourceMode.oauth.codexbarSourceMode, .oauth)
        XCTAssertEqual(CodexDataSourceMode.cli.codexbarSourceMode, .cli)
        XCTAssertEqual(CodexDataSourceMode.web.codexbarSourceMode, .web)
    }
}
