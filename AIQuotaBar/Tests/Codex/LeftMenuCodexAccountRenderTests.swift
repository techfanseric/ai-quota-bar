import SwiftUI
import XCTest
@testable import AIQuotaBar

/// 离屏渲染左键菜单的 Codex 账号分区（当前账号徽标 / 默认折叠 /
/// 非当前账号最后更新时间），供视觉验收。
/// 运行：swift test --filter LeftMenuCodexAccountRenderTests
@MainActor
final class LeftMenuCodexAccountRenderTests: XCTestCase {
    func testRenderCodexAccountSectionToPNG() throws {
        // 与本机 auth.json 对齐当前账号，命中「当前账号」判定。
        CodexLocalUsageModel.shared.refreshCurrentAccount()

        let viewModel = UsageViewModel()
        let now = Date()
        viewModel.providerUsageData = [
            .codex: UsageData(
                provider: .codex,
                remains: 2,
                total: 2,
                timestamp: now,
                models: [
                    makeModel(
                        account: "wangyang815@gmail.com",
                        name: "Weekly",
                        detail: "Pro 20x · Mix · resets 10/01 20:36",
                        remainingPercent: 84,
                        weeklyRemainingPercent: 84,
                        sampledAt: now.addingTimeInterval(-120),
                        windowStart: now.addingTimeInterval(-5 * 86_400),
                        windowEnd: now.addingTimeInterval(2 * 86_400)),
                    makeModel(
                        account: "marvaggarrett@gmail.com",
                        name: "5h",
                        detail: "Pro · Cloud · resets 09/26 18:00",
                        remainingPercent: 100,
                        weeklyRemainingPercent: nil,
                        sampledAt: now.addingTimeInterval(-2 * 3_600),
                        windowStart: now.addingTimeInterval(-5 * 3_600),
                        windowEnd: now.addingTimeInterval(-30 * 60)),
                    makeModel(
                        account: "marvaggarrett@gmail.com",
                        name: "Weekly",
                        detail: "Cloud · resets 09/28 09:00",
                        remainingPercent: 79,
                        weeklyRemainingPercent: 79,
                        sampledAt: now.addingTimeInterval(-2 * 3_600),
                        windowStart: now.addingTimeInterval(-5 * 86_400),
                        windowEnd: now.addingTimeInterval(2 * 86_400)),
                ],
                subscribeTitle: nil,
                subscribeEndTime: nil),
        ]

        let menu = MenuView(
            viewModel: viewModel,
            presentationSizing: MenuPresentationSizing(maximumScrollableHeight: 1_200),
            onOpenSettings: {},
            onLayoutChange: {})

        // 回归覆盖：非 Codex 供应商（GLM）的分组必须始终渲染模型行，
        // 不受「当前账号展开、其余收起」规则影响。
        let glmNow = Date()
        viewModel.providerUsageData[.glm] = UsageData(
            provider: .glm,
            remains: 2,
            total: 2,
            timestamp: glmNow,
            models: [
                makeGLMModel(
                    account: nil, name: "GLM-4.7", remainingPercent: 61,
                    windowStart: glmNow.addingTimeInterval(-3_600),
                    windowEnd: glmNow.addingTimeInterval(1_800)),
                makeGLMModel(
                    account: nil, name: "GLM-4.7 Weekly", remainingPercent: 88,
                    windowStart: glmNow.addingTimeInterval(-5 * 86_400),
                    windowEnd: glmNow.addingTimeInterval(2 * 86_400)),
            ],
            subscribeTitle: nil,
            subscribeEndTime: nil)

        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-quota-bar-leftmenu-render")
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)
        try render(
            menu, width: MenuBarPanelLayout.width, height: 1_200,
            name: "leftmenu-default", to: outputDirectory)

        // 变体：当前账号组也是过期云端数据，验证展开态的快照行布局
        // （行头 + 胶囊条 + 元数据，不退化成只剩周期行）。
        let staleViewModel = UsageViewModel()
        staleViewModel.providerUsageData = [
            .codex: UsageData(
                provider: .codex,
                remains: 2,
                total: 2,
                timestamp: now,
                models: [
                    makeModel(
                        account: "wangyang815@gmail.com",
                        name: "5h",
                        detail: "Pro · Cloud · resets 09/26 18:00",
                        remainingPercent: 100,
                        weeklyRemainingPercent: nil,
                        sampledAt: now.addingTimeInterval(-3 * 3_600),
                        windowStart: now.addingTimeInterval(-6 * 3_600),
                        windowEnd: now.addingTimeInterval(-60 * 60)),
                    makeModel(
                        account: "wangyang815@gmail.com",
                        name: "Weekly",
                        detail: "Cloud · resets 10/01 20:36",
                        remainingPercent: 84,
                        weeklyRemainingPercent: 84,
                        sampledAt: now.addingTimeInterval(-3 * 3_600),
                        windowStart: now.addingTimeInterval(-5 * 86_400),
                        windowEnd: now.addingTimeInterval(2 * 86_400)),
                ],
                subscribeTitle: nil,
                subscribeEndTime: nil)
        ]
        let staleMenu = MenuView(
            viewModel: staleViewModel,
            presentationSizing: MenuPresentationSizing(maximumScrollableHeight: 1_200),
            onOpenSettings: {},
            onLayoutChange: {})
        try render(
            staleMenu, width: MenuBarPanelLayout.width, height: 900,
            name: "leftmenu-stale-snapshot", to: outputDirectory)
    }

    private func makeGLMModel(
        account: String?,
        name: String,
        remainingPercent: Int,
        windowStart: Date,
        windowEnd: Date
    ) -> ModelUsageData {
        ModelUsageData(
            provider: .glm,
            accountName: account,
            modelName: name,
            currentIntervalTotal: 100,
            currentIntervalUsed: remainingPercent,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: Int(windowEnd.timeIntervalSinceNow * 1_000),
            startTime: windowStart,
            endTime: windowEnd,
            weeklyStartTime: nil,
            weeklyEndTime: nil,
            valueSuffix: "%",
            detailText: nil,
            currentIntervalRemainingPercent: remainingPercent,
            weeklyRemainingPercent: nil,
            progressBarPercentOverride: nil,
            progressBarRightText: nil,
            sampledAt: nil)
    }

    private func makeModel(
        account: String,
        name: String,
        detail: String,
        remainingPercent: Int,
        weeklyRemainingPercent: Int?,
        sampledAt: Date?,
        windowStart: Date,
        windowEnd: Date
    ) -> ModelUsageData {
        ModelUsageData(
            provider: .codex,
            accountName: account,
            modelName: name,
            currentIntervalTotal: 100,
            currentIntervalUsed: remainingPercent,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: Int(windowEnd.timeIntervalSinceNow * 1_000),
            startTime: windowStart,
            endTime: windowEnd,
            weeklyStartTime: name == "Weekly" ? windowStart : nil,
            weeklyEndTime: name == "Weekly" ? windowEnd : nil,
            valueSuffix: "%",
            detailText: detail,
            currentIntervalRemainingPercent: remainingPercent,
            weeklyRemainingPercent: weeklyRemainingPercent,
            progressBarPercentOverride: nil,
            progressBarRightText: nil,
            sampledAt: sampledAt)
    }

    private func render(
        _ view: some View,
        width: CGFloat,
        height: CGFloat,
        name: String,
        to directory: URL
    ) throws {
        let hostingView = NSHostingView(
            rootView: view
                .background(Color(nsColor: .controlBackgroundColor))
                .environment(\.colorScheme, .light)
                .frame(width: width, height: height))
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        hostingView.layoutSubtreeIfNeeded()

        // 在真实窗口里布局一帧，让动态颜色按浅色外观解析。
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: width, height: height)),
            styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = hostingView
        window.layoutIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(
            in: hostingView.bounds) else {
            XCTFail("Could not create a view bitmap for \(name).")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode the view bitmap for \(name).")
            return
        }
        let url = directory.appendingPathComponent("\(name).png")
        try png.write(to: url)
        print("[render] \(url.path)")
        window.orderOut(nil)
    }
}
