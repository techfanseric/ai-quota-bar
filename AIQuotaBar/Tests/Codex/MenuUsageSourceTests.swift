import XCTest
@testable import AIQuotaBar
@testable import CodexLocalUsageCore

/// 菜单用量卡片「本机/团队」切换的模型行为：默认本机、无团队连接时不动、
/// 五分钟节流、成员或团队变更即时失效、清理与成员回退。
/// 运行：swift test --filter MenuUsageSourceTests
@MainActor
final class MenuUsageSourceTests: XCTestCase {
    func testMenuDefaultsToLocalAndDoesNothingWithoutConnection() async {
        let model = makeModel()
        XCTAssertEqual(model.menuUsageSource, .local)
        model.menuUsageSource = .team
        await model.refreshTeamMenuUsage()
        XCTAssertNil(model.teamMenuError)
        XCTAssertTrue(model.teamMenuDaily.isEmpty)
        XCTAssertTrue(model.teamMenuHourly.isEmpty)
        XCTAssertFalse(model.teamMenuLoading)
    }

    func testTeamMenuRefreshThrottlesAndInvalidatesOnMemberOrBindingChange() {
        let model = makeModel()
        // 无缓存时必须拉取。
        XCTAssertTrue(model.shouldFetchTeamMenuUsage(now: Date(), binding: "binding-1", member: nil))

        let now = Date()
        model.teamMenuUpdatedAt = now
        model.teamMenuCacheBinding = "binding-1"
        model.teamMenuCacheMember = nil
        // 五分钟内的同团队同成员走缓存。
        XCTAssertFalse(model.shouldFetchTeamMenuUsage(now: now.addingTimeInterval(299), binding: "binding-1", member: nil))
        // 过期、换成员、换团队都要重新拉取。
        XCTAssertTrue(model.shouldFetchTeamMenuUsage(now: now.addingTimeInterval(301), binding: "binding-1", member: nil))
        XCTAssertTrue(model.shouldFetchTeamMenuUsage(now: now, binding: "binding-1", member: "member-2"))
        XCTAssertTrue(model.shouldFetchTeamMenuUsage(now: now, binding: "binding-2", member: nil))
    }

    func testClearTeamSummaryAlsoClearsMenuTeamUsage() {
        let model = makeModel()
        let now = Date()
        let event = LocalUsageEvent(
            id: "e", occurredAt: UsageTime.string(now.addingTimeInterval(-300)), model: "m",
            tokens: UsageTokens(input: 10), accountID: "a")
        model.teamMenuDaily = UsageHistory.buckets(events: [event], prices: [], days: 1, now: now)
        model.teamMenuHourly = UsageHistory.last24Hours(events: [event], prices: [], now: now)
        model.teamMenuError = "boom"
        model.teamMenuUpdatedAt = now

        model.clearTeamSummary()
        XCTAssertTrue(model.teamMenuDaily.isEmpty)
        XCTAssertTrue(model.teamMenuHourly.isEmpty)
        XCTAssertNil(model.teamMenuError)
        XCTAssertNil(model.teamMenuUpdatedAt)
        XCTAssertFalse(model.teamMenuLoading)
    }

    func testPruneMenuMemberSelectionDropsVanishedMember() {
        let model = makeModel()
        model.menuTeamMemberID = "member-1"
        model.pruneMenuMemberSelection([row(id: "member-2")])
        XCTAssertNil(model.menuTeamMemberID)

        model.menuTeamMemberID = "member-1"
        model.pruneMenuMemberSelection([row(id: "member-1"), row(id: "member-2")])
        XCTAssertEqual(model.menuTeamMemberID, "member-1")
    }

    private func makeModel() -> CodexLocalUsageModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return CodexLocalUsageModel(databaseURL: directory.appendingPathComponent("test.sqlite"))
    }

    private func row(id: String) -> TeamUsageRow {
        TeamUsageRow(
            id: id, name: "Member \(id)", memberID: id, records: 1, input: 10, output: 5,
            cached: 0, cacheWrite: 0, reasoning: 0, estimatedRecords: 0, pricedRecords: 0,
            costUSD: 0, cacheHitRate: nil)
    }
}
