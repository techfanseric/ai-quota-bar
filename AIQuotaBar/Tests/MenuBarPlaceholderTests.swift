import XCTest
@testable import AIQuotaBar

@MainActor
final class MenuBarPlaceholderTests: XCTestCase {
    func testFallbackStatePriority() {
        // 未配置任何凭证且未开启云同步 → 引导。
        XCTAssertEqual(
            UsageViewModel.menuBarFallbackState(
                hasAnyCredential: false,
                cloudSyncEnabled: false,
                hasFailure: false,
                isLoading: true,
                hasUsageData: false,
                isIntentionallyHidden: false),
            .needsSetup)

        // 刷新失败优先于加载与占位。
        XCTAssertEqual(
            UsageViewModel.menuBarFallbackState(
                hasAnyCredential: true,
                cloudSyncEnabled: false,
                hasFailure: true,
                isLoading: false,
                hasUsageData: true,
                isIntentionallyHidden: true),
            .failed)

        // 加载中优先于占位。
        XCTAssertEqual(
            UsageViewModel.menuBarFallbackState(
                hasAnyCredential: true,
                cloudSyncEnabled: true,
                hasFailure: false,
                isLoading: true,
                hasUsageData: false,
                isIntentionallyHidden: true),
            .loading)

        // 主动隐藏（跟随模式无活动窗口 / 全部暂停）→ 占位。
        XCTAssertEqual(
            UsageViewModel.menuBarFallbackState(
                hasAnyCredential: true,
                cloudSyncEnabled: true,
                hasFailure: false,
                isLoading: false,
                hasUsageData: true,
                isIntentionallyHidden: true),
            .placeholder)

        // 非主动隐藏的数据缺失保留原有 unavailable（警示色）。
        XCTAssertEqual(
            UsageViewModel.menuBarFallbackState(
                hasAnyCredential: true,
                cloudSyncEnabled: true,
                hasFailure: false,
                isLoading: false,
                hasUsageData: true,
                isIntentionallyHidden: false),
            .unavailable)
    }

    func testPlaceholderTooltipFollowMode() {
        XCTAssertEqual(
            AppLanguage.simplifiedChinese.menuBarPlaceholderTooltip(
                providerCount: 4,
                reason: .followMode),
            "AI Quota Bar\n已配置 4 家供应商 · 当前无活动窗口（跟随模式）")
        XCTAssertEqual(
            AppLanguage.english.menuBarPlaceholderTooltip(
                providerCount: 4,
                reason: .followMode),
            "AI Quota Bar\n4 providers configured · nothing to show (follow running apps)")
    }

    func testPlaceholderTooltipManuallyPaused() {
        XCTAssertEqual(
            AppLanguage.simplifiedChinese.menuBarPlaceholderTooltip(
                providerCount: 2,
                reason: .manuallyPaused),
            "AI Quota Bar\n已配置 2 家供应商 · 显示已手动暂停")
        XCTAssertEqual(
            AppLanguage.english.menuBarPlaceholderTooltip(
                providerCount: 2,
                reason: .manuallyPaused),
            "AI Quota Bar\n2 providers configured · display paused")
    }

    func testPlaceholderCountIsOptionalOnSnapshot() {
        let withoutCount = MenuBarSnapshot(
            provider: .codex,
            modelName: nil,
            remainingPercent: nil,
            ringPercent: nil,
            paceDeltaPercent: nil,
            resetsAt: nil,
            state: .placeholder,
            isLowQuota: false,
            tooltip: "")
        XCTAssertNil(withoutCount.placeholderProviderCount)

        let withCount = MenuBarSnapshot(
            provider: .codex,
            modelName: nil,
            remainingPercent: nil,
            ringPercent: nil,
            paceDeltaPercent: nil,
            resetsAt: nil,
            state: .placeholder,
            isLowQuota: false,
            tooltip: "",
            placeholderProviderCount: 4)
        XCTAssertEqual(withCount.placeholderProviderCount, 4)
        XCTAssertNotEqual(withoutCount, withCount)
    }

    func testPlaceholderStateText() {
        XCTAssertEqual(
            AppLanguage.simplifiedChinese.menuBarStateText(.placeholder),
            "无活动窗口")
        XCTAssertEqual(
            AppLanguage.english.menuBarStateText(.placeholder),
            "nothing to show")
    }
}
