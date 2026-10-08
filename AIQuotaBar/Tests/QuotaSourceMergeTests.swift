import XCTest
@testable import AIQuotaBar

/// 「本机 vs 云端取较新的一次采样」+「账号来源图标」这两条规则的回归。
///
/// 这块之前的行为是「同一个 cycle 本机永远赢，云端那份直接丢掉」，
/// 于是云端刚上报的快照会被本机一份旧值盖住 —— 表现就是"一直显示旧数字"。
/// 而"新不新"要靠 `sampledAt` 判断，所以这些测试同时钉住：没有任何一方
/// 缺时间戳时，必须退回本机优先，而不是随便挑一个。
final class QuotaSourceMergeTests: XCTestCase {

    private func model(
        provider: UsageProvider = .codex,
        account: String? = "a@example.com",
        name: String = "5h",
        percent: Int = 50,
        sampledAt: Date? = nil,
        source: String? = "OAuth",
        endTime: Date? = nil
    ) -> ModelUsageData {
        ModelUsageData(
            provider: provider, accountName: account, modelName: name,
            currentIntervalTotal: 100, currentIntervalUsed: percent,
            weeklyTotal: 0, weeklyUsed: 0, remainsTime: 3_600_000,
            startTime: nil, endTime: endTime ?? Date().addingTimeInterval(3600),
            weeklyStartTime: nil, weeklyEndTime: nil,
            valueSuffix: "%", detailText: source,
            currentIntervalRemainingPercent: percent, weeklyRemainingPercent: nil,
            progressBarPercentOverride: nil, progressBarRightText: nil,
            sampledAt: sampledAt)
    }

    // MARK: - 取较新

    func testCloudWinsWhenItWasSampledLater() {
        let older = Date().addingTimeInterval(-600)
        let local = model(percent: 12, sampledAt: older, source: "OAuth")
        let cloud = model(percent: 88, sampledAt: Date(), source: "Cloud")
        let winner = UsageViewModel.newerOfLocalAndCloud(local: local, cloud: cloud)
        XCTAssertEqual(winner.currentIntervalRemainingPercent, 88,
                       "云端五分钟前刚上报，不该被本机一份旧值盖掉")
    }

    func testLocalWinsWhenItWasSampledLater() {
        let local = model(percent: 12, sampledAt: Date(), source: "OAuth")
        let cloud = model(percent: 88, sampledAt: Date().addingTimeInterval(-600), source: "Cloud")
        let winner = UsageViewModel.newerOfLocalAndCloud(local: local, cloud: cloud)
        XCTAssertEqual(winner.currentIntervalRemainingPercent, 12)
    }

    func testEqualSampleTimesKeepTheLocalRow() {
        let at = Date()
        let local = model(percent: 12, sampledAt: at, source: "OAuth")
        let cloud = model(percent: 88, sampledAt: at, source: "Cloud")
        // 同一秒上报的两份数据没有先后可讲，本机优先是既有行为，不要在
        // 无关的改动里顺手翻掉。
        XCTAssertEqual(
            UsageViewModel.newerOfLocalAndCloud(local: local, cloud: cloud)
                .currentIntervalRemainingPercent, 12)
    }

    func testMissingSampleTimeFallsBackToLocalRatherThanPickingOne() {
        // 老发布方 / 某个接口不返回时间戳时，"无法比较"不等于"云端更新"。
        // 拿一份可能很旧的云端值当现值展示，比一直本机优先更难解释。
        let local = model(percent: 12, sampledAt: nil, source: "OAuth")
        let cloud = model(percent: 88, sampledAt: Date(), source: "Cloud")
        XCTAssertEqual(
            UsageViewModel.newerOfLocalAndCloud(local: local, cloud: cloud)
                .currentIntervalRemainingPercent, 12)
    }

    func testCloudWithoutATimeDoesNotBeatALocalRowThatHasOne() {
        let local = model(percent: 12, sampledAt: Date(), source: "OAuth")
        let cloud = model(percent: 88, sampledAt: nil, source: "Cloud")
        XCTAssertEqual(
            UsageViewModel.newerOfLocalAndCloud(local: local, cloud: cloud)
                .currentIntervalRemainingPercent, 12)
    }

    // MARK: - 来源种类

    func testSourceKindsComeFromTheDetailSourceSegment() {
        XCTAssertEqual(AccountSourceKind.kind(forSource: "Cloud"), .cloud)
        XCTAssertEqual(AccountSourceKind.kind(forSource: "cloud"), .cloud)
        XCTAssertEqual(AccountSourceKind.kind(forSource: " Watch "), .watch)
        XCTAssertEqual(AccountSourceKind.kind(forSource: "OAuth"), .local)
        XCTAssertEqual(AccountSourceKind.kind(forSource: "Codex CLI"), .local)
        // 认不出来的一律当本机：宁可少画一枚图标，也不能凭空说"来自云端"。
        XCTAssertEqual(AccountSourceKind.kind(forSource: nil), .local)
        XCTAssertEqual(AccountSourceKind.kind(forSource: "某个新来源"), .local)
    }

    func testMixIsNotASourceItIsTheResultOfMerging() {
        // Mix 由合并层写入，但它描述的是"两侧都有"，不是第三种来源。
        // 把它当来源会让本机+云端那一行画出两枚图标。
        XCTAssertEqual(AccountSourceKind.kind(forSource: "Mix"), .local)
    }

    func testIconsAreOrderedSoTheyDoNotJitterBetweenRefreshes() {
        let both: Set<AccountSourceKind> = [.watch, .cloud]
        XCTAssertEqual(AccountSourceKind.ordered(both), [.cloud, .watch])
        XCTAssertEqual(AccountSourceKind.ordered([.watch, .cloud]), [.cloud, .watch],
                       "Set 的遍历顺序不保证稳定，ordered 必须自己定序")
    }

    func testLocalCarriesNoIconBecauseNoIconIsHowLocalReads() {
        XCTAssertNil(AccountSourceKind.local.symbolName)
        XCTAssertEqual(AccountSourceKind.cloud.symbolName, "icloud")
        XCTAssertEqual(AccountSourceKind.watch.symbolName, "eye")
    }

    // MARK: - 合并后保留下来的来源集合

    func testAMergedRowRemembersBothSidesEvenThoughOnlyOneIsRendered() {
        let local = model(percent: 12, sampledAt: Date().addingTimeInterval(-600), source: "OAuth")
        let cloud = model(percent: 88, sampledAt: Date(), source: "Cloud")
        let winner = UsageViewModel.newerOfLocalAndCloud(local: local, cloud: cloud)
        // 只渲染赢家时，光看赢家分不出"本机独一份"和"本机 + 云端"。
        XCTAssertEqual(winner.accountSourceKinds, Set([.local, .cloud]))
    }

    func testAnUnmergedRowInfersItsOwnSingleKind() {
        XCTAssertEqual(model(source: "Cloud").accountSourceKinds, Set([.cloud]))
        XCTAssertEqual(model(source: "Watch").accountSourceKinds, Set([.watch]))
        XCTAssertEqual(model(source: "OAuth").accountSourceKinds, Set([.local]))
    }

    func testMergedSourceKindsSurviveADetailRewrite() {
        let row = model(source: "OAuth")
            .withMergedSourceKinds([.local, .cloud])
            .withDetailSource("Mix")
        XCTAssertEqual(row.accountSourceKinds, Set([.local, .cloud]),
                       "改写来源标签不该把参与过的来源一起抹掉")
        XCTAssertEqual(row.parsedDetail.source, "Mix")
    }

    // MARK: - 关注行 vs 本机/云端行

    /// 线上真实发生过的一次：同一个邮箱既是本机托管账号、又进了团队云端，
    /// 于是同一个 cycle 上既有 Cloud 行也有 Watch 行。老实说那个 Watch 行
    /// 是几秒前刚拉回来的，Cloud 行可能是两天前的 —— 结果显示的是旧值，
    /// 而且眼睛图标整个消失，读起来像"这个邮箱没关注上"。
    func testAFreshWatchedRowReplacesAnOlderCloudRowForTheSameCycle() {
        let staleCloud = model(
            percent: 84, sampledAt: Date().addingTimeInterval(-2 * 86_400),
            source: "Cloud")
        let freshWatch = model(percent: 69, sampledAt: Date(), source: "Watch")
        let merged = UsageViewModel.mergingWatchedRows(
            into: [staleCloud], watched: [freshWatch])
        XCTAssertEqual(merged.count, 1, "同一个 cycle 只能出一行")
        XCTAssertEqual(merged[0].currentIntervalRemainingPercent, 69,
                       "更近的那次采样才配得上显示")
    }

    func testAWatchedAccountThatIsAlsoCloudReportedShowsBothIcons() {
        let cloud = model(percent: 84, sampledAt: Date(), source: "Cloud")
        let watch = model(percent: 69, sampledAt: Date(), source: "Watch")
        let merged = UsageViewModel.mergingWatchedRows(
            into: [cloud], watched: [watch])
        XCTAssertEqual(merged[0].accountSourceKinds, Set([.cloud, .watch]))
        let symbols = AccountSourceKind.ordered(merged[0].accountSourceKinds)
            .compactMap(\.symbolName)
        XCTAssertEqual(symbols, ["icloud", "eye"],
                       "既被关注又在云端有数据，两枚图标都该在，不是二选一")
    }

    func testMergingAWatchedRowKeepsTheWinnerSourceSegment() {
        // "Cloud" 这一段还管着跨天快照的 M/d HH:mm 和云端可见周期上限。
        // 合成一行不该顺手把这些规则关掉。
        let cloud = model(percent: 84, sampledAt: Date(), source: "Cloud")
        let watch = model(percent: 69, sampledAt: Date().addingTimeInterval(-60), source: "Watch")
        let merged = UsageViewModel.mergingWatchedRows(
            into: [cloud], watched: [watch])
        XCTAssertEqual(merged[0].parsedDetail.source, "Cloud")
        XCTAssertEqual(merged[0].currentIntervalRemainingPercent, 84)
    }

    func testAWatchedRowWithNothingToMergeIntoIsAppendedAsIs() {
        let cloud = model(account: "other@example.com", source: "Cloud")
        let watch = model(percent: 85, sampledAt: Date(), source: "Watch")
        let merged = UsageViewModel.mergingWatchedRows(
            into: [cloud], watched: [watch])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.currentIntervalRemainingPercent), [50, 85])
        XCTAssertEqual(merged[1].accountSourceKinds, Set([.watch]))
    }

    func testTwoWatchedRowsNeverCollapseIntoOne() {
        let weekly = model(name: "Weekly", percent: 69, sampledAt: Date(), source: "Watch")
        let fiveHour = model(name: "5h", percent: 40, sampledAt: Date(), source: "Watch")
        let merged = UsageViewModel.mergingWatchedRows(
            into: [], watched: [weekly, fiveHour])
        XCTAssertEqual(merged.count, 2, "cycle 名不同就是两行")
    }

    func testAMissingSampleTimeDoesNotLetTheWatchedRowWinByDefault() {
        // "无法比较"不等于"关注那一路更新" —— 那是在替数据编先后。
        let cloud = model(percent: 84, sampledAt: Date(), source: "Cloud")
        let watch = model(percent: 69, sampledAt: nil, source: "Watch")
        let merged = UsageViewModel.mergingWatchedRows(
            into: [cloud], watched: [watch])
        XCTAssertEqual(merged[0].currentIntervalRemainingPercent, 84)
        XCTAssertEqual(merged[0].accountSourceKinds, Set([.cloud, .watch]))
    }

    // MARK: - 采样时间不是窗口边界

    func testTheProvidersThatUsedToCarryNoSampleTimeNowDo() {
        // 三个接口都不返回服务端时间戳，但"什么时候量的"仍然要说出来 ——
        // 否则合并层永远没法比较，这套"取较新"对它们等于没开。
        // 这里钉住的是 mapper 的输出形状，真正的值由各自的单测覆盖。
        for provider in [UsageProvider.kimi, .glm, .miniMax] {
            let row = model(provider: provider, sampledAt: Date(), source: nil)
            XCTAssertNotNil(row.sampledAt, "\(provider.rawValue) 的本机行必须有采样时间")
        }
    }
}
