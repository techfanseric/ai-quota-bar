import XCTest
@testable import AIQuotaBar

/// 「关注账号」走公开云端通道后的行为契约。
///
/// 这个功能的边界比团队同步宽得多——地址本身就是查找键——所以测试要守住的
/// 不是「谁能读」，而是：发布出去的内容有多窄、撤销是否即时、以及三种
/// 「看不到数据」有没有被混成一团。
@MainActor
final class CodexWatchTests: XCTestCase {
    private func makeStore() -> (CodexWatchStore, UserDefaults) {
        let suite = "codexwatch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (CodexWatchStore(defaults: defaults), defaults)
    }

    private func model(
        _ account: String?,
        _ name: String = "5h",
        percent: Int = 50,
        sampledAt: Date? = nil,
        endTime: Date? = nil,
        plan: String? = "Plus"
    ) -> ModelUsageData {
        ModelUsageData(
            provider: .codex, accountName: account, modelName: name,
            currentIntervalTotal: 100, currentIntervalUsed: percent,
            weeklyTotal: 0, weeklyUsed: 0, remainsTime: 3_600_000,
            startTime: nil, endTime: endTime ?? Date().addingTimeInterval(3600),
            weeklyStartTime: nil, weeklyEndTime: nil,
            valueSuffix: "%",
            detailText: plan.map { "\($0) · Codex" },
            currentIntervalRemainingPercent: percent,
            weeklyRemainingPercent: nil,
            progressBarPercentOverride: nil, progressBarRightText: nil,
            sampledAt: sampledAt)
    }

    private func codexUsage(_ models: [ModelUsageData]) -> UsageData {
        UsageData(
            provider: .codex,
            remains: models.count, total: models.count,
            timestamp: Date(), models: models,
            subscribeTitle: nil, subscribeEndTime: nil)
    }

    // MARK: - 发布内容：只有勾选的账号

    func testSharingOffPublishesNothing() {
        let (store, _) = makeStore()
        // 开关没开 = 一个都不发布。团队通道的原有行为不受影响。
        XCTAssertFalse(store.isSharing)
        let usage = codexUsage([model("a@example.com")])
        XCTAssertTrue(store.publishableSnapshots(from: usage).isEmpty)
    }

    func testOnlyCheckedAccountsArePublished() {
        let (store, _) = makeStore()
        store.isSharing = true
        store.setShared(true, for: "keep@example.com")
        let usage = codexUsage([
            model("keep@example.com", "5h", percent: 61),
            model("drop@example.com", "5h", percent: 10),
        ])
        let published = store.publishableSnapshots(from: usage)
        XCTAssertEqual(published.map(\.account), ["keep@example.com"])
        XCTAssertEqual(published.first?.plan, "Plus")
        XCTAssertEqual(published.first?.windows.first?.remainingPercent, 61)
    }

    func testSharingOnWithNothingCheckedPublishesNothing() {
        let (store, _) = makeStore()
        store.isSharing = true
        // 默认拒绝：开了开关但一个都没勾，等于什么都不发布。
        XCTAssertTrue(store.publishableSnapshots(
            from: codexUsage([model("a@example.com")])).isEmpty)
    }

    func testUnpublishedAccountIsDroppedEvenIfChecked() {
        let (store, _) = makeStore()
        store.isSharing = true
        store.setShared(true, for: "gone@example.com")
        // 勾了但那台机器当前没有这个账号的额度，不能发一个空壳上去。
        XCTAssertTrue(store.publishableSnapshots(
            from: codexUsage([model("other@example.com")])).isEmpty)
    }

    func testNonCodexUsageIsNeverPublished() {
        let (store, _) = makeStore()
        store.isSharing = true
        store.setShared(true, for: "a@example.com")
        let kimi = UsageData(
            provider: .kimi, remains: 1, total: 1, timestamp: Date(),
            models: [ModelUsageData(
                provider: .kimi, accountName: "a@example.com", modelName: "5h",
                currentIntervalTotal: 100, currentIntervalUsed: 50,
                weeklyTotal: 0, weeklyUsed: 0, remainsTime: 0,
                startTime: nil, endTime: nil, weeklyStartTime: nil, weeklyEndTime: nil,
                valueSuffix: "%", detailText: nil,
                currentIntervalRemainingPercent: 50, weeklyRemainingPercent: nil,
                progressBarPercentOverride: nil, progressBarRightText: nil, sampledAt: nil)],
            subscribeTitle: nil, subscribeEndTime: nil)
        XCTAssertTrue(store.publishableSnapshots(from: kimi).isEmpty)
    }

    func testWindowsCarryOnlyPercentagesNotAbsoluteCounts() {
        let (store, _) = makeStore()
        store.isSharing = true
        store.setShared(true, for: "a@example.com")
        let usage = codexUsage([model("a@example.com", "5h", percent: 37)])
        let window = store.publishableSnapshots(from: usage)[0].windows[0]
        // 百分比是额度唯一的对外形状：绝对量会暴露这个人真实烧了多少。
        XCTAssertEqual(window.remainingPercent, 37)
        XCTAssertNotEqual(window.remainingPercent, 63)
    }

    func testPublishedSampleTimeIsNeverTheWindowResetTime() {
        let (store, _) = makeStore()
        store.isSharing = true
        store.setShared(true, for: "a@example.com")
        // 这一行没有任何采样时刻，而它的 endTime 在 5 天之后（周窗口的 resetsAt）。
        let weeklyReset = Date().addingTimeInterval(5 * 86_400)
        let usage = codexUsage([
            model("a@example.com", "Weekly", percent: 43, endTime: weeklyReset),
        ])
        let window = store.publishableSnapshots(from: usage)[0].windows[0]
        // 兜底曾经是 model.endTime，于是发布出去的是一个未来的时刻：读侧菜单显示
        // 「更新于 10/11 23:59」，而数据是几分钟前的。没有时间可以，未来的时间不行。
        XCTAssertNotEqual(window.sampledAt, weeklyReset,
                          "a sample time is never a window boundary")
        XCTAssertLessThanOrEqual(window.sampledAt ?? .distantFuture, Date())
        XCTAssertEqual(window.sampledAt, usage.timestamp,
                       "no per-model sample time means the fetch time, not the reset time")
    }

    func testDuplicateWindowsKeepTheFreshestSample() {
        let (store, _) = makeStore()
        store.isSharing = true
        store.setShared(true, for: "a@example.com")
        let old = Date().addingTimeInterval(-3600)
        let usage = codexUsage([
            model("a@example.com", "5h", percent: 20, sampledAt: old),
            model("a@example.com", "5h", percent: 80, sampledAt: Date()),
        ])
        let windows = store.publishableSnapshots(from: usage)[0].windows
        XCTAssertEqual(windows.count, 1, "同名窗口只出一条")
        XCTAssertEqual(windows[0].remainingPercent, 80)
    }

    func testCaseInsensitiveAccountMatching() {
        let (store, _) = makeStore()
        store.isSharing = true
        store.setShared(true, for: "User@Example.com")
        let usage = codexUsage([model("USER@example.com", "5h", percent: 44)])
        XCTAssertEqual(store.publishableSnapshots(from: usage).count, 1)
    }

    // MARK: - 可分享账号的来源

    func testPublishableAccountsFollowTheAccountsWithLiveQuota() {
        let (store, _) = makeStore()
        store.isSharing = true
        store.setShared(true, for: "y17321008998@gmail.com")
        // A Codex CLI sign-in lives in ~/.codex/auth.json and has live quota, but
        // is NOT in the app's managed account store. Publishing keys off the quota
        // data, so such an account must still be shareable.
        let usage = codexUsage([
            model("y17321008998@gmail.com", "5h", percent: 77),
            model("y17321008998@gmail.com", "Weekly", percent: 62),
        ])
        let published = store.publishableSnapshots(from: usage)
        XCTAssertEqual(published.map(\.account), ["y17321008998@gmail.com"])
        // Both windows of one account travel together.
        XCTAssertEqual(Set(published[0].windows.map(\.name)), ["5h", "Weekly"])
    }

    func testSharingOnWithNoLocalQuotaPublishesNothingRatherThanWipingTheCloud() {
        let (store, _) = makeStore()
        store.isSharing = true
        store.setShared(true, for: "a@example.com")
        // usageData == nil is the "this cycle produced no local Codex quota" case.
        // publishableSnapshots must be empty, and the caller must NOT treat that as
        // "unshare everything" -- see refreshCodexWatch(), which fetches first.
        XCTAssertTrue(store.publishableSnapshots(from: nil).isEmpty)
    }

    func testATeamMatesCloudAccountIsNeverPublishable() {
        let (store, _) = makeStore()
        store.isSharing = true
        store.setShared(true, for: "colleague@example.com")
        // The share list is the owner's explicit choice; what protects a teammate's
        // account is that the publish source is local quota data, never the
        // cloud-merged menu view. So a name that is only ticked publishes nothing.
        XCTAssertTrue(store.publishableSnapshots(
            from: codexUsage([model("mine@example.com")])).isEmpty)
    }

    // MARK: - 关注名单

    func testWatchAddsNormalizesAndRejectsDuplicates() {
        let (store, _) = makeStore()
        XCTAssertTrue(store.watch("Someone@Example.com"))
        XCTAssertEqual(store.watchedAccountNames, ["Someone@Example.com"])
        XCTAssertFalse(store.watch("someone@example.com"))
        XCTAssertEqual(store.watchedAccountNames.count, 1)
    }

    func testUnwatchDropsTheCachedSnapshot() {
        let (store, _) = makeStore()
        store.watch("a@example.com")
        // 取消关注后必须丢掉快照，否则菜单里会继续显示一个已经不再关注的账号。
        XCTAssertEqual(store.status(for: "a@example.com"), .notShared)
        store.unwatch("A@EXAMPLE.COM")
        XCTAssertTrue(store.watchedAccountNames.isEmpty)
        XCTAssertTrue(store.watchedModels.isEmpty)
    }

    func testWatchRejectsMalformedInput() {
        let (store, _) = makeStore()
        for bad in ["", "   ", "no-at-sign", "@example.com", "a@", "a@b",
                    "a b@example.com", "a@example.com/path",
                    "https://example.com", "a@example..com", "a@.com"]
        {
            XCTAssertFalse(store.watch(bad), "should reject \(bad)")
        }
        XCTAssertTrue(store.watchedAccountNames.isEmpty)
    }

    func testWatchAndShareListsAreIndependent() {
        let (store, _) = makeStore()
        store.isSharing = true
        store.setShared(true, for: "mine@example.com")
        store.watch("theirs@example.com")
        XCTAssertTrue(store.isShared("mine@example.com"))
        XCTAssertFalse(store.isShared("theirs@example.com"))
        XCTAssertTrue(store.isWatched("theirs@example.com"))
        XCTAssertFalse(store.isWatched("mine@example.com"))
    }

    // MARK: - 状态

    func testUnknownAddressIsNotShared() {
        let (store, _) = makeStore()
        store.watch("a@example.com")
        XCTAssertEqual(store.status(for: "a@example.com"), .notShared)
    }

    func testStatusForAnEmptyAccountIsNotShared() {
        let (store, _) = makeStore()
        XCTAssertEqual(store.status(for: "   "), .notShared)
    }

    func testStaleMarkerWinsOverACachedSnapshot() {
        let (store, _) = makeStore()
        store.watch("a@example.com")
        store.seedSnapshotForTesting(
            account: "a@example.com",
            snapshot: CodexWatchSnapshot(
                account: "a@example.com", plan: "Plus",
                windows: [CodexWatchWindow(
                    name: "5h", remainingPercent: 40,
                    resetsAt: Date(), sampledAt: Date().addingTimeInterval(-9000),
                    startsAt: Date().addingTimeInterval(-5 * 3600))],
                publishedAt: Date().addingTimeInterval(-9000)))
        if case .available = store.status(for: "a@example.com") {} else {
            XCTFail("a fresh snapshot should read as available")
        }

        store.markStaleForTesting("a@example.com")
        // The row stays (a watched account must not vanish) but must not read as
        // current: the cached numbers are 2.5 hours old.
        XCTAssertEqual(store.status(for: "a@example.com"), .stale)
        XCTAssertEqual(store.watchedModels.count, 1,
                       "the stale row is still rendered, just labelled")
    }

    func testWatchingSomethingSharedRendersRows() {
        let (store, _) = makeStore()
        store.watch("a@example.com")
        store.seedSnapshotForTesting(
            account: "a@example.com",
            snapshot: CodexWatchSnapshot(
                account: "a@example.com", plan: "Plus",
                windows: [CodexWatchWindow(
                    name: "5h", remainingPercent: 40,
                    resetsAt: Date().addingTimeInterval(3600), sampledAt: Date(),
                    startsAt: Date().addingTimeInterval(-5 * 3600))],
                publishedAt: Date()))
        let rows = store.watchedModels
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].provider, .codex)
        XCTAssertEqual(rows[0].accountName, "a@example.com")
        XCTAssertEqual(rows[0].currentIntervalRemainingPercent, 40)
        XCTAssertEqual(rows[0].currentIntervalTotal, 100,
                       "the shareable shape is a percentage, never an absolute count")
    }

    func testFutureSampleTimeFromAnOldPublisherFallsBackToPublishedAt() {
        let (store, _) = makeStore()
        store.watch("a@example.com")
        // 线上真实存着的一条：发布方把周窗口的结束时刻当成了采样时刻。
        let publishedAt = Date().addingTimeInterval(-300)
        let reset = Date().addingTimeInterval(5 * 86_400)
        store.seedSnapshotForTesting(
            account: "a@example.com",
            snapshot: CodexWatchSnapshot(
                account: "a@example.com", plan: "Pro 5x",
                windows: [CodexWatchWindow(
                    name: "Weekly", remainingPercent: 43,
                    resetsAt: reset, sampledAt: reset,
                    startsAt: Date().addingTimeInterval(-2 * 86_400))],
                publishedAt: publishedAt))
        let row = store.watchedModels[0]
        // 菜单右端显示的「更新于」读的是 sampledAt。未来的时刻读起来像
        // 「五天后才更新」，会去判断是不是坏了 —— 退回发布时刻才对。
        XCTAssertEqual(row.sampledAt, publishedAt,
                       "a future sample time is not a time, it is a bug report")
        XCTAssertEqual(row.endTime, reset,
                       "the reset time is still shown as the reset time")
    }

    // MARK: - 地址 → 云端查找键

    func testAccountKeyMatchesTheServerSideDigest() {
        // The client hashes locally to map read counts back to its own addresses,
        // so this must stay byte-identical to the worker's `digestKey`. It is a
        // known-answer test: if either side's normalization changes, the owner sees
        // "read 0 times" and never finds out why.
        XCTAssertEqual(
            CodexWatchCloudClient.accountKey(for: "y17321008998@gmail.com"),
            "b8cf896879af36ea2a9e48ccc510e000052ff457ce1aa57d428befc5d5116b34")
    }

    func testAccountKeyNormalizesBeforeHashing() {
        XCTAssertEqual(
            CodexWatchCloudClient.accountKey(for: "  User@Example.COM "),
            CodexWatchCloudClient.accountKey(for: "user@example.com"))
    }

    func testAccountKeyRejectsMalformedAddresses() {
        XCTAssertNil(CodexWatchCloudClient.accountKey(for: "not-an-email"))
        XCTAssertNil(CodexWatchCloudClient.accountKey(for: ""))
    }

    // MARK: - 持久化

    func testBothListsSurviveReload() {
        let (store, defaults) = makeStore()
        store.isSharing = true
        store.setShared(true, for: "mine@example.com")
        store.watch("theirs@example.com")

        let reloaded = CodexWatchStore(defaults: defaults)
        XCTAssertTrue(reloaded.isSharing)
        XCTAssertTrue(reloaded.isShared("mine@example.com"))
        XCTAssertTrue(reloaded.isWatched("theirs@example.com"))
    }

    func testOnChangeFiresForShareAndWatchEditsButNotForNoOps() {
        let (store, _) = makeStore()
        var changes = 0
        store.onChange = { changes += 1 }
        store.isSharing = true
        store.setShared(true, for: "a@example.com")
        store.watch("b@example.com")
        store.unwatch("b@example.com")
        XCTAssertEqual(changes, 4)
        // 重复投递同一个值不该触发：那会让 SwiftUI 每次重建都打一轮云端。
        store.setShared(true, for: "a@example.com")
        XCTAssertEqual(changes, 4)
    }

    func testUncheckingForgetsTheReadCount() {
        let (store, _) = makeStore()
        store.isSharing = true
        store.setShared(true, for: "a@example.com")
        store.setShared(false, for: "a@example.com")
        // 已经不再分享的账号不该继续显示历史读取次数。
        XCTAssertTrue(store.readCounts.isEmpty)
    }

    // MARK: - v1.32.x 迁移

    func testMigratesLegacyGrantKeys() {
        let suite = "codexwatch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "codexWatch.isServing")
        defaults.set([[1, "keep@example.com"], [0, "denied@example.com"]],
                     forKey: "codexWatch.grants.v1")

        let store = CodexWatchStore(defaults: defaults)
        XCTAssertTrue(store.isSharing)
        XCTAssertTrue(store.isShared("keep@example.com"))
        XCTAssertEqual(store.sharedAccountNames, ["keep@example.com"])
    }

    // MARK: - 归一化

    func testNormalizeTrimsAndLowercases() {
        XCTAssertEqual(CodexWatchStore.normalize("  A@B.COM \n"), "a@b.com")
        XCTAssertEqual(CodexWatchStore.normalize("   "), "")
    }
}
