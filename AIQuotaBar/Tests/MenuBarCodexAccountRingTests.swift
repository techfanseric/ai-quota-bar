import XCTest
@testable import AIQuotaBar

/// Codex 账号环在视图模型层的调度。
///
/// 覆盖三件事：
/// 1. 没有账号在用时，Codex 那一栏的行为与改动前完全一致（单个环）。
/// 2. 多个账号同时在用时，一个账号一个环，每个环显示那个账号自己的额度。
/// 3. 账号身份用网关报的邮箱（`accountKey`）判定，别名不会让它对不上。
@MainActor
final class MenuBarCodexAccountRingTests: XCTestCase {
    private let accountA = "node.cyberic@gmail.com"
    private let accountB = "1104524667@qq.com"
    private let accountC = "marvaggarrett@gmail.com"

    /// 这些偏好存在**进程级**的 `UserDefaults.standard` 里 —— 改了不还原
    /// 会漏到别的测试上（曾经把配额窗口改成 current，导致移动看板的
    /// ringPercent 断言失败）。
    private var savedDefaults: [(key: String, value: Any?)] = []

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        let keys = [
            MenuBarAppearance.storageKey,
            MenuBarRingDisplayMode.storageKey,
            MenuBarRingPreferences.providersKey,
            MenuBarRingQuotaWindow.storageKey,
            MenuBarProviderRingWindows.storageKey,
            CloudSyncSettings.enabledKey,
            MenuAccountPrivacy.storageKey,
        ]
        savedDefaults = keys.map { key in
            (key: key, value: defaults.object(forKey: key))
        }
        defaults.set(MenuBarAppearance.compactRing.rawValue, forKey: MenuBarAppearance.storageKey)
        defaults.set(MenuBarRingDisplayMode.all.rawValue, forKey: MenuBarRingDisplayMode.storageKey)
        defaults.set(false, forKey: CloudSyncSettings.enabledKey)
        defaults.set(false, forKey: MenuAccountPrivacy.storageKey)
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        for saved in savedDefaults {
            if let value = saved.value {
                defaults.set(value, forKey: saved.key)
            } else {
                defaults.removeObject(forKey: saved.key)
            }
        }
        savedDefaults = []
        super.tearDown()
    }

    // MARK: - Idle keeps the single-ring behaviour

    func testIdleAccountsKeepTheSingleCodexRing() {
        let viewModel = makeViewModel()
        viewModel.codexAccountUsage = .idle

        let codexRings = viewModel.menuBarSnapshots.filter { $0.provider == .codex }
        XCTAssertEqual(codexRings.count, 1)
        XCTAssertNil(codexRings.first?.accountKey)
        XCTAssertFalse(codexRings.first?.isAccountActive ?? true)
    }

    func testAmbiguousAttributionKeepsTheSingleCodexRing() {
        let viewModel = makeViewModel()
        viewModel.codexAccountUsage = MagpieAccountUsage(
            state: .ambiguous, busyCounts: [:], unattributedRequests: 2)

        let codexRings = viewModel.menuBarSnapshots.filter { $0.provider == .codex }
        XCTAssertEqual(codexRings.count, 1)
        XCTAssertFalse(codexRings.first?.isAccountActive ?? true)
    }

    // MARK: - Active accounts get one ring each

    func testTwoActiveAccountsRenderOneRingPerAccount() {
        let viewModel = makeViewModel()
        viewModel.codexAccountUsage = MagpieAccountUsage(
            state: .active([accountA, accountB]),
            busyCounts: [accountA: 2, accountB: 1],
            unattributedRequests: 0)

        let codexRings = viewModel.menuBarSnapshots.filter { $0.provider == .codex }
        XCTAssertEqual(codexRings.count, 2)
        XCTAssertEqual(
            codexRings.compactMap(\.accountKey), [accountA, accountB])
        XCTAssertTrue(codexRings.allSatisfy(\.isAccountActive))
    }

    func testEachAccountRingShowsThatAccountsOwnQuota() {
        let viewModel = makeViewModel()
        viewModel.codexAccountUsage = MagpieAccountUsage(
            state: .active([accountA, accountB]),
            busyCounts: [accountA: 1, accountB: 1],
            unattributedRequests: 0)

        let codexRings = viewModel.menuBarSnapshots.filter { $0.provider == .codex }
        let ringA = codexRings.first { $0.accountKey == accountA }
        let ringB = codexRings.first { $0.accountKey == accountB }
        XCTAssertEqual(ringA?.remainingPercent, 71)
        XCTAssertEqual(ringB?.remainingPercent, 44)
    }

    func testBusyAccountOrderIsStableAcrossLoadFluctuation() {
        let viewModel = makeViewModel()
        viewModel.codexAccountUsage = MagpieAccountUsage(
            state: .active([accountA, accountB]),
            busyCounts: [accountA: 1, accountB: 1],
            unattributedRequests: 0)
        let first = viewModel.menuBarSnapshots
            .filter { $0.provider == .codex }
            .compactMap(\.accountKey)

        // 同数时按账号名定序 —— 环的位置是用户唯一能用来区分的线索，
        // 它不能因为负载波动而左右跳动。
        viewModel.codexAccountUsage = MagpieAccountUsage(
            state: .active([accountB, accountA]),
            busyCounts: [accountB: 1, accountA: 1],
            unattributedRequests: 0)
        let second = viewModel.menuBarSnapshots
            .filter { $0.provider == .codex }
            .compactMap(\.accountKey)

        XCTAssertEqual(first, second)
    }

    func testAliasAccountNamesStillMatchTheGatewayIdentity() {
        let viewModel = makeViewModel(aliases: [accountA: "work"])
        viewModel.codexAccountUsage = MagpieAccountUsage(
            state: .active([accountA]),
            busyCounts: [accountA: 1],
            unattributedRequests: 0)

        let codexRings = viewModel.menuBarSnapshots.filter { $0.provider == .codex }
        XCTAssertEqual(codexRings.count, 1)
        XCTAssertEqual(codexRings.first?.accountKey, accountA)
        // 显示名用用户自己起的别名 —— 那正是给他看的。
        XCTAssertTrue(codexRings.first?.tooltip.contains("work") ?? false)
    }

    func testMoreActiveAccountsThanTheRingCapAreTrimmed() {
        let viewModel = makeViewModel()
        viewModel.codexAccountUsage = MagpieAccountUsage(
            state: .active([accountA, accountB, accountC, "wangyang815@gmail.com"]),
            busyCounts: [
                accountA: 1, accountB: 1, accountC: 1, "wangyang815@gmail.com": 1,
            ],
            unattributedRequests: 0)

        let codexRings = viewModel.menuBarSnapshots.filter { $0.provider == .codex }
        XCTAssertEqual(codexRings.count, UsageViewModel.maximumCodexAccountRings)
        let tooltip = codexRings.map(\.tooltip).joined(separator: "\n")
        XCTAssertTrue(tooltip.contains("wangyang815@gmail.com"))
    }

    func testActiveAccountWithoutAQuotaRowKeepsAnUnavailableRing() {
        let viewModel = makeViewModel()
        viewModel.codexAccountUsage = MagpieAccountUsage(
            state: .active([accountA, "missing@example.com"]),
            busyCounts: [accountA: 1, "missing@example.com": 1],
            unattributedRequests: 0)

        let codexRings = viewModel.menuBarSnapshots.filter { $0.provider == .codex }
        XCTAssertEqual(codexRings.count, 2)
        let missing = codexRings.first { $0.accountKey == "missing@example.com" }
        XCTAssertEqual(missing?.state, .unavailable)
        XCTAssertTrue(missing?.tooltip.contains("missing@example.com") ?? false)
    }

    func testUnavailableActivityKeepsLastKnownAccountAndExplainsIt() {
        let viewModel = makeViewModel()
        viewModel.codexAccountUsage = MagpieAccountUsage(
            state: .active([accountA]),
            busyCounts: [accountA: 1],
            unattributedRequests: 0)
        viewModel.codexAccountUsage = MagpieAccountUsage(
            state: .unavailable,
            busyCounts: [accountA: 1],
            unattributedRequests: 0)

        let codexRings = viewModel.menuBarSnapshots.filter { $0.provider == .codex }
        XCTAssertEqual(codexRings.compactMap(\.accountKey), [accountA])
        let tooltip = codexRings.first?.tooltip ?? ""
        let unavailableText = viewModel.appLanguage == .simplifiedChinese
            ? "无法读取正在使用的账号"
            : "Active account information is unavailable"
        XCTAssertTrue(tooltip.contains(unavailableText))
    }

    func testAmbiguousActivityExplainsWhyOnlyOneCodexRingIsShown() {
        let viewModel = makeViewModel()
        viewModel.codexAccountUsage = MagpieAccountUsage(
            state: .ambiguous, busyCounts: [:], unattributedRequests: 2)

        let codexRings = viewModel.menuBarSnapshots.filter { $0.provider == .codex }
        XCTAssertEqual(codexRings.count, 1)
        let tooltip = codexRings.first?.tooltip ?? ""
        let attributionText = viewModel.appLanguage == .simplifiedChinese
            ? "无法确定使用账号"
            : "account attribution is unavailable"
        XCTAssertTrue(tooltip.contains(attributionText))
    }

    func testAccountRingTooltipNamesTheAccountAndSaysItIsInUse() {
        let viewModel = makeViewModel()
        viewModel.codexAccountUsage = MagpieAccountUsage(
            state: .active([accountA, accountB]),
            busyCounts: [accountA: 1, accountB: 1],
            unattributedRequests: 0)

        let codexRings = viewModel.menuBarSnapshots.filter { $0.provider == .codex }
        guard let tooltip = codexRings.first(where: {
            $0.accountKey == accountA
        })?.tooltip else {
            return XCTFail("expected an account ring tooltip")
        }
        XCTAssertTrue(tooltip.contains(accountA))
        // 语言跟着用户的设置走，所以断言"正在使用"这层语义，而不是某一
        // 种语言的字面。
        let inUseText = viewModel.appLanguage == .simplifiedChinese
            ? "正在使用"
            : "In use now"
        XCTAssertTrue(tooltip.contains(inUseText))
    }

    func testAccountIdentityLookupResolvesAliasesToTheGatewayIdentity() {
        let viewModel = makeViewModel(aliases: [accountA: "work"])
        XCTAssertEqual(viewModel.codexAccountKey(forAccountName: "work"), accountA)
        XCTAssertEqual(viewModel.codexAccountKey(forAccountName: accountA), accountA)
        XCTAssertNil(viewModel.codexAccountKey(forAccountName: "unknown alias"))
    }

    func testEveryBusyAccountIncludingAliasesIsExpandedByTheMenu() {
        let viewModel = makeViewModel(aliases: [accountA: "work"])
        viewModel.codexAccountUsage = MagpieAccountUsage(
            state: .active([accountA, accountB]),
            busyCounts: [accountA: 1, accountB: 1],
            unattributedRequests: 0)

        XCTAssertTrue(viewModel.isCodexAccountInUse("work"))
        XCTAssertTrue(viewModel.isCodexAccountInUse(accountB))
        XCTAssertFalse(viewModel.isCodexAccountInUse(accountC))
    }

    func testMenuTreatsAnUnavailableSnapshotAsNoLongerConfirmedInUse() {
        let viewModel = makeViewModel()
        viewModel.codexAccountUsage = MagpieAccountUsage(
            state: .unavailable,
            busyCounts: [accountA: 1],
            unattributedRequests: 0)

        XCTAssertFalse(viewModel.isCodexAccountInUse(accountA))
    }

    // MARK: - Helpers

    private func makeViewModel(
        aliases: [String: String] = [:]
    ) -> UsageViewModel {
        let viewModel = UsageViewModel()
        viewModel.menuBarRingSelectedProviders = Set(MenuBarRingPreferences.providerOrder)
        viewModel.usageData = UsageData(
            provider: .codex,
            remains: 2,
            total: 2,
            timestamp: Date(),
            models: [
                makeCodexModel(
                    account: accountA,
                    alias: aliases[accountA],
                    modelName: "5h",
                    remainingPercent: 71),
                makeCodexModel(
                    account: accountB,
                    alias: aliases[accountB],
                    modelName: "5h",
                    remainingPercent: 44),
                makeCodexModel(
                    account: accountC,
                    alias: aliases[accountC],
                    modelName: "5h",
                    remainingPercent: 23),
            ],
            subscribeTitle: nil,
            subscribeEndTime: nil)
        return viewModel
    }

    private func makeCodexModel(
        account: String,
        alias: String?,
        modelName: String,
        remainingPercent: Int
    ) -> ModelUsageData {
        let now = Date()
        return ModelUsageData(
            provider: .codex,
            accountName: alias ?? account,
            modelName: modelName,
            currentIntervalTotal: 100,
            currentIntervalUsed: remainingPercent,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: 3_600_000,
            startTime: now.addingTimeInterval(-3_600),
            endTime: now.addingTimeInterval(3_600),
            weeklyStartTime: nil,
            weeklyEndTime: nil,
            valueSuffix: "%",
            detailText: "Pro · Magpie",
            currentIntervalRemainingPercent: remainingPercent,
            weeklyRemainingPercent: nil,
            progressBarPercentOverride: nil,
            progressBarRightText: nil,
            sampledAt: nil,
            accountKey: account)
    }
}
