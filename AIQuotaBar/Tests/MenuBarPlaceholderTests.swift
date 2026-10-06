import AppKit
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
            ringTrend: nil,
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
            ringTrend: nil,
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

    // MARK: - 占位形态偏好

    func testPlaceholderStyleDefaultsToConnectivity() {
        let defaults = UserDefaults(suiteName: "MenuBarPlaceholderTests.defaults")!
        defaults.removePersistentDomain(forName: "MenuBarPlaceholderTests.defaults")
        XCTAssertEqual(MenuBarPlaceholderStyle.stored(in: defaults), .openAIConnectivity)
    }

    func testPlaceholderStyleRoundTripsThroughDefaults() {
        let name = "MenuBarPlaceholderTests.roundTrip"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        for style in MenuBarPlaceholderStyle.allCases {
            defaults.set(style.rawValue, forKey: MenuBarPlaceholderStyle.storageKey)
            XCTAssertEqual(MenuBarPlaceholderStyle.stored(in: defaults), style)
        }
    }

    /// 旧的布尔 key 不再被读取 —— 连通性形态要真的接管默认，而不是被
    /// 「上次勾过显示数量」悄悄顶回旧的二选一。
    func testLegacyShowsCountKeyIsIgnored() {
        let name = "MenuBarPlaceholderTests.legacy"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "menuBarPlaceholderShowsCount")
        XCTAssertEqual(MenuBarPlaceholderStyle.stored(in: defaults), .openAIConnectivity)
        defaults.set(false, forKey: "menuBarPlaceholderShowsCount")
        XCTAssertEqual(MenuBarPlaceholderStyle.stored(in: defaults), .openAIConnectivity)
    }

    // MARK: - 连通性记号

    /// 记号必须待在环的内圈里。越界不会报错、也不会有测试变红，只会在二十
    /// 几像素的菜单栏里糊到弧上 —— 那是肉眼才看得出的回归。
    func testConnectivityGlyphsStayInsideTheRing() {
        let center = NSPoint(x: 183.5, y: 183.5)
        let ringInnerRadius = 155.975 - 55.05 / 2
        let padding = 8.0
        for (name, glyph) in [
            ("check", QuotaSymbolRenderer.checkMark),
            ("cross", QuotaSymbolRenderer.crossMark),
        ] {
            // 取包围盒四角而不是折线顶点：包围盒一定包住整条路径，判定因此
            // 是保守的 —— 通过即证明整条记号都在环内圈里。
            let box = glyph.bounds
            for point in [
                NSPoint(x: box.minX, y: box.minY), NSPoint(x: box.maxX, y: box.maxY),
                NSPoint(x: box.minX, y: box.maxY), NSPoint(x: box.maxX, y: box.minY),
            ] {
                let radius = hypot(point.x - center.x, point.y - center.y)
                    + QuotaSymbolRenderer.connectivityGlyphLineWidth / 2
                XCTAssertLessThan(
                    radius, ringInnerRadius - padding,
                    "\(name) glyph corner reaches \(radius), ring inner edge is \(ringInnerRadius)")
            }
        }
    }

    /// 对勾的包围盒中心必须落在环心。折线重心偏右下（右侧那笔更长），
    /// 按重心摆会让整个记号看着往右下歪。
    func testCheckMarkBoundingBoxIsCentredOnTheRing() {
        let bounds = QuotaSymbolRenderer.checkMark.bounds
        XCTAssertEqual(bounds.midX, 183.5, accuracy: 0.5)
        XCTAssertEqual(bounds.midY, 183.5, accuracy: 0.5)
    }

    /// 对勾与叉的视觉体量要相当，否则一个粗一个细，看着像两个不同语义。
    func testCheckAndCrossHaveComparableExtent() {
        let check = QuotaSymbolRenderer.checkMark.bounds
        let cross = QuotaSymbolRenderer.crossMark.bounds
        XCTAssertEqual(check.width, cross.width, accuracy: 30)
        XCTAssertEqual(check.height, cross.height, accuracy: 30)
    }

    // MARK: - Tooltip

    func testPlaceholderConnectivityTooltipCoversEveryState() {
        for (state, zh, en) in [
            (CodexConnectivityState.reachable, "OpenAI 可达", "OpenAI reachable"),
            (CodexConnectivityState.unreachable, "OpenAI 不可达", "OpenAI unreachable"),
            (CodexConnectivityState.unknown, "正在探测 OpenAI…", "Probing OpenAI…"),
        ] {
            XCTAssertEqual(
                AppLanguage.simplifiedChinese.placeholderConnectivityTooltip(
                    base: "AI Quota Bar", connectivity: state),
                "AI Quota Bar\n\(zh)")
            XCTAssertEqual(
                AppLanguage.english.placeholderConnectivityTooltip(
                    base: "AI Quota Bar", connectivity: state),
                "AI Quota Bar\n\(en)")
        }
    }
    /// 走真实 `StatusBarCompactRingView`（不是直接调渲染函数）在 22pt 菜单栏尺寸下
/// 出图，确认三态都真的画了东西、且彼此不同。
///
/// 光有几何断言不够：几何对了但 `draw()` 分支接错、或者三个状态走了同一条
/// 路径，几何测试照样全绿，而这个洞只有在真实 view 出图时才会暴露。
    func testConnectivityStatesRenderDistinctGlyphs() throws {
        let side: CGFloat = 22
        func raster(_ connectivity: CodexConnectivityState) throws -> [UInt8] {
            let view = StatusBarCompactRingView(frame: NSRect(x: 0, y: 0, width: side, height: side))
            view.setSnapshot(
                MenuBarSnapshot(
                    provider: .codex, modelName: nil, remainingPercent: nil, ringPercent: nil,
                    paceDeltaPercent: nil, ringTrend: nil, resetsAt: nil, state: .placeholder,
                    isLowQuota: false, tooltip: "", placeholderProviderCount: 4),
                connectivity: connectivity,
                placeholderStyle: .openAIConnectivity,
                accessibilityLabel: "")
            let cache = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            cache.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: cache)
            let data = try XCTUnwrap(cache.bitmapData)
            return Array(UnsafeBufferPointer(start: data, count: cache.bytesPerRow * cache.pixelsHigh))
        }

        let reachable = try raster(.reachable)
        let unreachable = try raster(.unreachable)
        let unknown = try raster(.unknown)

        // 非空：菜单栏底色本身不是透明，整幅都有值，所以改为「不止一种颜色」。
        for (name, pixels) in [("reachable", reachable), ("unreachable", unreachable), ("unknown", unknown)] {
            XCTAssertGreaterThan(Set(pixels).count, 1, "\(name) rendered a flat raster")
        }
        XCTAssertNotEqual(reachable, unreachable, "reachable and unreachable drew the same glyph")
        XCTAssertNotEqual(reachable, unknown, "reachable and probing drew the same glyph")
        XCTAssertNotEqual(unreachable, unknown, "unreachable and probing drew the same glyph")
    }
    }
