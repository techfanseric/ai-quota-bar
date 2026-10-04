import XCTest
@testable import AIQuotaBar

/// 「关注账号」走团队云端通道后的行为契约。
///
/// 这里守住三件事，任何一条破了都是用户能直接看见的故障：
/// 1. 打开分享开关后，**只有勾选的 Codex 账号**可以离开这台 Mac；
/// 2. 没打开开关的老用户，上报行为一个字都不变；
/// 3. 关注名单的增删、邮箱校验、跨重启持久化。
@MainActor
final class CodexWatchTests: XCTestCase {
    private func makeStore() -> (CodexWatchStore, UserDefaults) {
        let suite = "codexwatch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (CodexWatchStore(defaults: defaults), defaults)
    }

    private func model(
        _ provider: UsageProvider,
        _ account: String?,
        _ name: String = "5h"
    ) -> ModelUsageData {
        ModelUsageData(
            provider: provider, accountName: account, modelName: name,
            currentIntervalTotal: 100, currentIntervalUsed: 50,
            weeklyTotal: 0, weeklyUsed: 0, remainsTime: 3_600_000,
            startTime: nil, endTime: nil,
            weeklyStartTime: nil, weeklyEndTime: nil,
            valueSuffix: "%", detailText: nil,
            currentIntervalRemainingPercent: 50, weeklyRemainingPercent: nil,
            progressBarPercentOverride: nil, progressBarRightText: nil, sampledAt: nil)
    }

    // MARK: - 分享侧：上报过滤

    func testSharingOffKeepsExistingUploadBehaviour() {
        let (store, _) = makeStore()
        XCTAssertFalse(store.isSharing)
        let models = [model(.codex, "a@example.com"), model(.kimi, "k@example.com")]
        // 开关没开 = 用户没启用关注功能，绝不能顺手改变既有团队共享行为。
        XCTAssertEqual(store.uploadableModels(models).map(\.id),
                       models.map(\.id))
    }

    func testSharingOnUploadsOnlyCheckedCodexAccounts() {
        let (store, _) = makeStore()
        store.isSharing = true
        store.setShared(true, for: "keep@example.com")
        let models = [
            model(.codex, "keep@example.com"),
            model(.codex, "drop@example.com"),
        ]
        XCTAssertEqual(store.uploadableModels(models).map(\.accountName),
                       ["keep@example.com"])
    }

    func testSharingOnWithNothingCheckedUploadsNoCodexAccount() {
        let (store, _) = makeStore()
        store.isSharing = true
        // 默认拒绝：开了开关但一个都没勾，等于什么都不共享。
        XCTAssertTrue(store.uploadableModels([model(.codex, "a@example.com")]).isEmpty)
    }

    func testSharingFilterLeavesOtherProvidersAlone() {
        let (store, _) = makeStore()
        store.isSharing = true
        // 这个开关只管 Codex，不该顺手改变 Kimi / GLM / MiniMax 的团队共享。
        let others = [model(.kimi, "k@example.com"), model(.glm, "g@example.com")]
        XCTAssertEqual(store.uploadableModels(others).count, 2)
    }

    func testSharingFilterDropsUnattributedCodexQuota() {
        let (store, _) = makeStore()
        store.isSharing = true
        store.setShared(true, for: "a@example.com")
        // 账号名为空的未归属额度没法被按邮箱关注，留着只会让人以为在共享。
        XCTAssertTrue(store.uploadableModels([model(.codex, nil)]).isEmpty)
        XCTAssertTrue(store.uploadableModels([model(.codex, "  ")]).isEmpty)
    }

    func testUncheckingAccountRemovesItFromNextUpload() {
        let (store, _) = makeStore()
        store.isSharing = true
        store.setShared(true, for: "a@example.com")
        XCTAssertEqual(store.uploadableModels([model(.codex, "a@example.com")]).count, 1)
        store.setShared(false, for: "a@example.com")
        XCTAssertTrue(store.uploadableModels([model(.codex, "a@example.com")]).isEmpty)
    }

    func testShareListMatchesCaseAndWhitespaceInsensitively() {
        let (store, _) = makeStore()
        store.isSharing = true
        store.setShared(true, for: "User@Example.com")
        XCTAssertTrue(store.isShared("user@example.com"))
        XCTAssertTrue(store.isShared("  USER@EXAMPLE.COM  "))
        XCTAssertTrue(store.uploadableModels([model(.codex, "USER@example.com")]).count == 1)
    }

    func testShareListHasNoDuplicates() {
        let (store, _) = makeStore()
        store.isSharing = true
        store.setShared(true, for: "a@example.com")
        store.setShared(false, for: "a@example.com")
        store.setShared(true, for: "A@Example.com")
        XCTAssertEqual(store.sharedAccountNames.count, 1)
    }

    // MARK: - 关注侧：名单

    func testWatchAddsNormalizesAndRejectsDuplicates() {
        let (store, _) = makeStore()
        XCTAssertTrue(store.watch("Someone@Example.com"))
        XCTAssertEqual(store.watchedAccountNames, ["Someone@Example.com"])
        // 大小写不同的同一个邮箱不算新增。
        XCTAssertFalse(store.watch("someone@example.com"))
        XCTAssertEqual(store.watchedAccountNames.count, 1)
    }

    func testUnwatchRemovesRegardlessOfCase() {
        let (store, _) = makeStore()
        store.watch("a@example.com")
        store.unwatch("A@EXAMPLE.COM")
        XCTAssertTrue(store.watchedAccountNames.isEmpty)
        // 移除不存在的邮箱不应崩溃，也不应误删别的条目。
        store.watch("b@example.com")
        store.unwatch("zzz@example.com")
        XCTAssertEqual(store.watchedAccountNames, ["b@example.com"])
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

    func testWatchAcceptsRealisticEmails() {
        let (store, _) = makeStore()
        for good in ["a@example.com", "first.last+tag@sub.example.co.uk",
                     "y17321008998@gmail.com", "UPPER@EXAMPLE.COM"]
        {
            XCTAssertTrue(store.watch(good), "should accept \(good)")
        }
        XCTAssertEqual(store.watchedAccountNames.count, 4)
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

    func testOnChangeFiresForShareAndWatchEdits() {
        let (store, _) = makeStore()
        var changes = 0
        store.onChange = { changes += 1 }
        store.isSharing = true
        store.setShared(true, for: "a@example.com")
        store.watch("b@example.com")
        store.unwatch("b@example.com")
        XCTAssertEqual(changes, 4)
        // 重复赋值同值不该触发。
        store.setShared(true, for: "a@example.com")
        XCTAssertEqual(changes, 4)
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
        // 只搬放行项，显式拒绝不搬。
        XCTAssertTrue(store.isShared("keep@example.com"))
        XCTAssertEqual(store.sharedAccountNames, ["keep@example.com"])
    }

    // MARK: - 归一化

    func testNormalizeTrimsAndLowercases() {
        XCTAssertEqual(CodexWatchStore.normalize("  A@B.COM \n"), "a@b.com")
        XCTAssertEqual(CodexWatchStore.normalize("   "), "")
    }
}
