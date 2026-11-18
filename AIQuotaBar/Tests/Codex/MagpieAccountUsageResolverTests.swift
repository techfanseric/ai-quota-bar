import XCTest
@testable import AIQuotaBar

final class MagpieAccountUsageResolverTests: XCTestCase {
    private func snapshot(
        isConfigured: Bool = true,
        isAvailable: Bool = true,
        requests: [MagpieModelActivitySnapshot.Request] = [],
        lanes: [String: Int] = [:]
    ) -> MagpieModelActivitySnapshot {
        MagpieModelActivitySnapshot(
            isConfigured: isConfigured,
            isAvailable: isAvailable,
            providerIDs: ["magpie"],
            requests: requests,
            lanes: lanes)
    }

    func testSingleActiveAccountIsResolvedFromTraceSeat() {
        let usage = MagpieAccountUsageResolver.resolve(snapshot(requests: [
            .init(id: 1, provider: .codex, model: "gpt-6.1-terra",
                accountKey: "node.cyberic@gmail.com"),
        ]))
        XCTAssertEqual(usage.state, .active(["node.cyberic@gmail.com"]))
        XCTAssertEqual(usage.busyCounts, ["node.cyberic@gmail.com": 1])
        XCTAssertTrue(usage.isAvailable)
    }

    func testMultipleActiveAccountsAreOrderedByBusyCountThenName() {
        let usage = MagpieAccountUsageResolver.resolve(snapshot(
            requests: [
                .init(id: 1, provider: .codex, model: "gpt-6.1-terra",
                    accountKey: "b@example.com"),
                .init(id: 2, provider: .codex, model: "gpt-6.1-terra",
                    accountKey: "a@example.com"),
                .init(id: 3, provider: .codex, model: "gpt-6.1-terra",
                    accountKey: "b@example.com"),
            ],
            lanes: ["codex@b@example.com": 2, "codex@a@example.com": 1]))
        // b 忙两��，a 忙一次；同数时按名字定序。
        XCTAssertEqual(usage.activeAccounts, ["b@example.com", "a@example.com"])
        XCTAssertEqual(usage.busyCounts["b@example.com"], 2)
        XCTAssertEqual(usage.busyCounts["a@example.com"], 1)
    }

    func testEqualBusyCountsKeepAStableOrder() {
        // 顺序稳定是硬要求：环的位置是用户区分多个 C 环的唯一线索之一，
        // 它不能在负载波动时左右跳。
        let first = MagpieAccountUsageResolver.ordered([
            "z@example.com": 1, "a@example.com": 1,
        ])
        let second = MagpieAccountUsageResolver.ordered([
            "a@example.com": 1, "z@example.com": 1,
        ])
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, ["a@example.com", "z@example.com"])
    }

    func testLaneAndTraceDoNotDoubleCountTheSameRequest() {
        // 同一个请求在 trace（seat）和车道（busy）里都被数到，是**同一个**
        // 请求，不是两个。取较大值，不相加。
        let usage = MagpieAccountUsageResolver.resolve(snapshot(
            requests: [
                .init(id: 1, provider: .codex, model: "gpt-6.1-terra",
                    accountKey: "a@example.com"),
            ],
            lanes: ["codex@a@example.com": 1]))
        XCTAssertEqual(usage.busyCounts["a@example.com"], 1)
        XCTAssertEqual(usage.activeAccounts.count, 1)
    }

    func testLaneCoversRequestsTraceCouldNotAttribute() {
        // trace 归属不到（无 seat）时，车道仍然能说出是哪个账号在服务。
        let usage = MagpieAccountUsageResolver.resolve(snapshot(
            requests: [
                .init(id: 1, provider: .codex, model: "gpt-6.1-terra"),
            ],
            lanes: ["codex@a@example.com": 1]))
        XCTAssertEqual(usage.state, .active(["a@example.com"]))
        XCTAssertEqual(usage.busyCounts["a@example.com"], 1)
    }

    func testUnattributedRequestsAreAmbiguousNotIdle() {
        // 有请求在途但说不出是哪个账号 —— 归属不可知**不是**"没有在用"。
        let usage = MagpieAccountUsageResolver.resolve(snapshot(requests: [
            .init(id: 1, provider: .codex, model: "gpt-6.1-terra"),
        ]))
        XCTAssertEqual(usage.state, .ambiguous)
        XCTAssertEqual(usage.unattributedRequests, 1)
        XCTAssertTrue(usage.isAvailable)
        XCTAssertTrue(usage.activeAccounts.isEmpty)
    }

    func testUnavailableGatewayIsNotIdle() {
        // 读失败不等于空闲：状态必须是 unavailable，环不能因此清零。
        let usage = MagpieAccountUsageResolver.resolve(snapshot(isAvailable: false))
        XCTAssertEqual(usage.state, .unavailable)
        XCTAssertFalse(usage.isAvailable)
    }

    func testUnconfiguredGatewayIsIdle() {
        let usage = MagpieAccountUsageResolver.resolve(snapshot(isConfigured: false))
        XCTAssertEqual(usage.state, .idle)
        XCTAssertTrue(usage.isAvailable)
    }

    func testNoRequestsIsIdle() {
        let usage = MagpieAccountUsageResolver.resolve(snapshot())
        XCTAssertEqual(usage.state, .idle)
        XCTAssertTrue(usage.busyCounts.isEmpty)
    }

    func testBareCodexLaneIsNotAttributedToAnAccount() {
        // 裸 `codex` 是 Codex 当前登录着的那个账号：它与网关共用 rest id，
        // 不可区分是哪个邮箱 —— 不猜。
        XCTAssertNil(MagpieAccountUsageResolver.accountKey(
            fromLane: "codex", provider: .codex))
        XCTAssertEqual(MagpieAccountUsageResolver.accountKey(
            fromLane: "codex@User@Example.com", provider: .codex),
            "user@example.com")
        XCTAssertNil(MagpieAccountUsageResolver.accountKey(
            fromLane: "kimi-code#abc", provider: .codex))
    }

    func testOtherProviderLanesAreIgnored() {
        // Kimi / MiniMax 的车道与 Codex 账号无关，不能算进 Codex 的归属。
        let usage = MagpieAccountUsageResolver.resolve(snapshot(
            lanes: ["kimi-code#cb455f3d91": 1, "minimax-cn#ac6489c389": 1]))
        XCTAssertEqual(usage.state, .idle)
    }

    func testNonCodexRequestsDoNotBecomeCodexAccounts() {
        let usage = MagpieAccountUsageResolver.resolve(snapshot(requests: [
            .init(id: 1, provider: .kimi, model: "k3.1-pro",
                accountKey: "a@example.com"),
        ]))
        XCTAssertEqual(usage.state, .idle)
    }
}
