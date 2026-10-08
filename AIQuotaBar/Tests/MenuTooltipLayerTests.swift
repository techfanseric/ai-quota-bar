import AppKit
import SwiftUI
import XCTest
@testable import AIQuotaBar

/// 菜单 tooltip 的回归护栏。
///
/// 这里测的不是"气泡好不好看"，是**那条静默失效的链路**：锚点几何上报不到
/// 根层时，`MenuTooltipLayer` 不报任何错、不崩，只是气泡永远不出现；反过来
/// 「移开后不消失」也是同一条链路上的静默失效。两条都只能靠实渲染比对来盯。
///
/// 判据用 A/B 图比对而不是"图是不是纯色" —— 探针本身就有色块，纯色判据恒真，
/// 等于什么都没验。
final class MenuTooltipLayerTests: XCTestCase {
    private struct Probe: View {
        let hoveredID: String?

        var body: some View {
            VStack(spacing: 0) {
                Color.red
                    .frame(height: 40)
                    .menuTooltipAnchor(id: "a", lines: ["AAA"], isHovered: hoveredID == "a")
                Color.green
                    .frame(height: 40)
                    .menuTooltipAnchor(id: "b", lines: ["BBB", "CCC"], isHovered: hoveredID == "b")
            }
            .frame(width: 200, height: 300)
            .modifier(MenuTooltipLayer())
        }
    }

    @MainActor
    func testBubbleFollowsTheHoveredAnchorAndLeavesWithIt() throws {
        let canvas = try Canvas()
        defer { canvas.close() }

        let idle = try canvas.snapshot(hoveredID: nil)
        let hoveredA = try canvas.snapshot(hoveredID: "a")
        XCTAssertNotEqual(idle, hoveredA, "悬停第一行应当画出气泡")

        let hoveredB = try canvas.snapshot(hoveredID: "b")
        XCTAssertNotEqual(hoveredA, hoveredB, "换一个锚点，气泡内容应当跟着换")

        // 这条就是"指针移开气泡不消失"的回归：悬停撤掉之后必须回到未悬停的样子。
        let backToIdle = try canvas.snapshot(hoveredID: nil)
        XCTAssertEqual(idle, backToIdle, "悬停撤掉后气泡必须消失")
    }

    @MainActor
    private final class Canvas {
        private let hosting: NSHostingView<AnyView>
        private let window: NSWindow

        init() throws {
            hosting = NSHostingView(
                rootView: AnyView(Probe(hoveredID: nil).frame(width: 200, height: 300)))
            hosting.frame = NSRect(x: 0, y: 0, width: 200, height: 300)
            window = NSWindow(
                contentRect: hosting.frame,
                styleMask: [.titled],
                backing: .buffered,
                defer: false)
            window.contentView = hosting
            window.orderFront(nil)
            hosting.layoutSubtreeIfNeeded()
        }

        func close() {
            window.orderOut(nil)
        }

        /// 换悬停状态 → 跑完 350ms 延迟 → 截一张图。
        ///
        /// 延迟必须真的等掉：`.task(id:)` 是在 id 变化后**先**藏再计时重显，
        /// 立刻截图只会拍到"还没画"，测的是一个中间态。
        func snapshot(hoveredID: String?) -> Data {
            hosting.rootView = AnyView(Probe(hoveredID: hoveredID).frame(width: 200, height: 300))
            hosting.layoutSubtreeIfNeeded()
            let deadline = Date().addingTimeInterval(1.2)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                hosting.layoutSubtreeIfNeeded()
            }
            let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            return rep.representation(using: .png, properties: [:])!
        }
    }
}