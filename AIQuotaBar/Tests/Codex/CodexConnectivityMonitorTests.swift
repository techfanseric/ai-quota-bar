import XCTest
@testable import AIQuotaBar

final class CodexConnectivityMonitorTests: XCTestCase {
    func testEitherOpenAIHostKeepsConnectivityReachable() async {
        let reachableHosts = Set(["openai.com"])
        let checker = CodexConnectivityChecker { url in
            reachableHosts.contains(url.host ?? "")
        }

        let state = await checker.check()

        XCTAssertEqual(state, .reachable)
    }

    func testBothOpenAIHostsMustFailBeforeConnectivityIsUnreachable() async {
        let checker = CodexConnectivityChecker { _ in false }

        let state = await checker.check()

        XCTAssertEqual(state, .unreachable)
    }

    func testJitterMapsRandomUnitIntoEightToTwelveSeconds() {
        XCTAssertEqual(CodexConnectivityMonitor.jitteredInterval(unitRandom: -1), 8)
        XCTAssertEqual(CodexConnectivityMonitor.jitteredInterval(unitRandom: 0), 8)
        XCTAssertEqual(CodexConnectivityMonitor.jitteredInterval(unitRandom: 0.5), 10)
        XCTAssertEqual(CodexConnectivityMonitor.jitteredInterval(unitRandom: 1), 12)
        XCTAssertEqual(CodexConnectivityMonitor.jitteredInterval(unitRandom: 2), 12)
    }
}
