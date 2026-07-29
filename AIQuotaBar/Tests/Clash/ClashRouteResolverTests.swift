import XCTest
@testable import AIQuotaBar

final class ClashRouteResolverTests: XCTestCase {
    func testResolvesSelectorFromAIRuleSet() {
        let groupName = "[类]-海外AI🤖"
        let proxies = [
            groupName: ClashProxy(
                name: groupName,
                type: "Selector",
                now: "日本 01",
                all: ["日本 01", "新加坡 01"],
                history: nil),
            "日本 01": ClashProxy(
                name: "日本 01",
                type: "Vless",
                now: nil,
                all: nil,
                history: nil),
        ]
        let rules = [
            ClashRule(
                type: "RuleSet",
                payload: "private_domain",
                proxy: "DIRECT"),
            ClashRule(
                type: "RuleSet",
                payload: "ai",
                proxy: groupName),
        ]

        XCTAssertEqual(
            ClashOpenAIRouteResolver.resolveGroupName(
                rules: rules,
                proxies: proxies),
            groupName)
    }

    func testDoesNotMistakePrivateDomainForAIRuleSet() {
        let unrelatedGroup = "Manual"
        let proxies = [
            unrelatedGroup: ClashProxy(
                name: unrelatedGroup,
                type: "Selector",
                now: "Node",
                all: ["Node"],
                history: nil),
        ]
        let rules = [
            ClashRule(
                type: "RuleSet",
                payload: "private_domain",
                proxy: unrelatedGroup),
        ]

        XCTAssertNil(
            ClashOpenAIRouteResolver.resolveGroupName(
                rules: rules,
                proxies: proxies))
    }

    func testSorterPlacesSuccessfulLowestLatencyFirstAndTimeoutsLast() {
        let routes = [
            ClashRoute(name: "timeout", type: "Vless", delay: 0, isSelected: false),
            ClashRoute(name: "slow", type: "Vless", delay: 210, isSelected: false),
            ClashRoute(name: "unknown", type: "Vless", delay: nil, isSelected: false),
            ClashRoute(name: "fast", type: "Vless", delay: 72, isSelected: true),
        ]

        XCTAssertEqual(
            ClashRouteSorter.sorted(routes).map(\.name),
            ["fast", "slow", "timeout", "unknown"])
    }
}
