import XCTest
@testable import AIQuotaBar

final class ClashRouteFilterTests: XCTestCase {
    private let routes = [
        ClashRoute(
            name: "🇯🇵 Tokyo 01",
            type: "Vless",
            delay: 82,
            isSelected: false),
        ClashRoute(
            name: "日本-家宽-02",
            type: "Hysteria2",
            delay: 95,
            isSelected: true),
        ClashRoute(
            name: "SG-Singapore-01",
            type: "Vmess",
            delay: 61,
            isSelected: false),
        ClashRoute(
            name: "US Los Angeles",
            type: "Trojan",
            delay: 140,
            isSelected: false),
    ]

    func testFuzzyCountryAliasesMatchFlagChineseAndISOCode() {
        for query in ["🇯🇵", "日本", "JP", "Japan"] {
            let result = ClashRouteFilter.filter(
                routes,
                query: query,
                usesRegularExpression: false)

            XCTAssertEqual(
                Set(result.routes.map(\.name)),
                Set(["🇯🇵 Tokyo 01", "日本-家宽-02"]),
                "query: \(query)")
            XCTAssertNil(result.errorMessage)
        }
    }

    func testFuzzyFilterStillMatchesArbitraryNodeText() {
        let result = ClashRouteFilter.filter(
            routes,
            query: "家宽",
            usesRegularExpression: false)

        XCTAssertEqual(result.routes.map(\.name), ["日本-家宽-02"])
    }

    func testRegularExpressionSupportsAnchorsAndAlternation() {
        let result = ClashRouteFilter.filter(
            routes,
            query: #"^(🇯🇵|SG-).*(01)$"#,
            usesRegularExpression: true)

        XCTAssertEqual(
            Set(result.routes.map(\.name)),
            Set(["🇯🇵 Tokyo 01", "SG-Singapore-01"]))
        XCTAssertNil(result.errorMessage)
    }

    func testRegularExpressionMatchesOriginalNameInsteadOfCountryAliases() {
        let result = ClashRouteFilter.filter(
            routes,
            query: #"^JP"#,
            usesRegularExpression: true)

        XCTAssertTrue(result.routes.isEmpty)
    }

    func testInvalidRegularExpressionReturnsErrorAndNoRoutes() {
        let result = ClashRouteFilter.filter(
            routes,
            query: #"^(JP|SG"#,
            usesRegularExpression: true)

        XCTAssertTrue(result.routes.isEmpty)
        XCTAssertNotNil(result.errorMessage)
    }

    @MainActor
    func testFilterEditingStartsReadOnlyAndRequiresExplicitEntry() {
        let suiteName = "ClashRouteFilterTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(#"^(JP|SG)"#, forKey: "clashRouteFilterQuery")

        let viewModel = ClashRouteViewModel(defaults: defaults)

        XCTAssertFalse(viewModel.isFilterEditing)
        viewModel.beginFilterEditing()
        XCTAssertTrue(viewModel.isFilterEditing)
        viewModel.endFilterEditing()
        XCTAssertFalse(viewModel.isFilterEditing)
        XCTAssertEqual(viewModel.filterQuery, #"^(JP|SG)"#)
    }
}
