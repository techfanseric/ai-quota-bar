import SwiftUI

/// 菜单里一个可悬停的 tooltip 锚点。
///
/// 悬停状态和几何位置**一起**上报：根层要知道「现在悬停的是哪一行」才能决定画哪个
/// 气泡，同时要拿到这一行在根坐标系里的位置才能摆气泡。只上报其中一个都不够 ——
/// 只报 id 就只能贴在行里（会被 ScrollView 裁掉），只报位置就得再传一条回调链
/// 把悬停事件从 ProviderModelsSection 一层层捅回 MenuView。
struct MenuTooltipAnchor: Equatable {
    /// 全局唯一的锚点名。必须带上 provider：不同供应商下同名账号会撞车，
    /// 撞车时后一个会顶掉前一个，气泡就会显示成另一个账号的内容。
    let id: String
    let lines: [String]
    /// 在 `.named(MenuTooltipAnchorKey.coordinateSpaceName)` 坐标系里的位置。
    let frame: CGRect
    let isHovered: Bool
}

struct MenuTooltipAnchorKey: PreferenceKey {
    static let coordinateSpaceName = "MenuTooltipAnchor"

    static let defaultValue: [MenuTooltipAnchor] = []

    static func reduce(value: inout [MenuTooltipAnchor], nextValue: () -> [MenuTooltipAnchor]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// 把这一块登记成菜单 tooltip 的候选锚点。
    func menuTooltipAnchor(id: String, lines: [String], isHovered: Bool) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: MenuTooltipAnchorKey.self,
                    value: [
                        MenuTooltipAnchor(
                            id: id,
                            lines: lines,
                            frame: proxy.frame(
                                in: .named(MenuTooltipAnchorKey.coordinateSpaceName)),
                            isHovered: isHovered)
                    ])
            }
        }
    }
}

/// 菜单根层上的 tooltip 宿主。
///
/// **为什么不直接用 `.help()`**：MenuView 整个活在 `NSMenu` 的 item view 里
/// （见 `MenuBarNativeMenu.make`），而 NSMenu 的 modal 事件跟踪循环会吃掉菜单项
/// 内部的鼠标移动/移出事件 —— 挂在里面的 `NSTrackingArea` 收不到 mouse-exited，
/// AppKit 于是以为指针还停在那儿，把 tooltip 窗口留在屏幕上不撤。表现就是
/// 指针早就移开了，气泡还赖在那里。
///
/// 悬停这条链路改成自己做：`onHover` 给的 false 就是收，行为完全可控。
/// 代价是气泡得画在根层（行里放不下、也会被 ScrollView 裁掉），所以这里
/// 收全菜单的锚点、排一个出来。
struct MenuTooltipLayer: ViewModifier {
    /// 和系统 tooltip 一个量级的延迟。悬停延迟不是可有可无的：账号行和 cycle
    /// 芯片是紧挨着的列表，鼠标横扫过去时没有延迟就是一串闪个不停的空泡。
    private static let showDelay: UInt64 = 350_000_000

    /// 每一轮布局上报的锚点表。悬停期间行会因为刷新而重排、内容里的时间也会变，
    /// 所以气泡画的时候现查这张表，而不是在悬停那一刻把文案抄一份下来。
    @State private var anchors: [String: MenuTooltipAnchor] = [:]
    @State private var hoveredID: String?
    @State private var presentedID: String?

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: MenuTooltipAnchorKey.coordinateSpaceName)
            .onPreferenceChange(MenuTooltipAnchorKey.self) { reported in
                let table = Dictionary(
                    reported.map { ($0.id, $0) },
                    uniquingKeysWith: { _, latest in latest })
                if table != anchors {
                    anchors = table
                }
                let hovered = reported.last(where: \.isHovered)?.id
                if hovered != hoveredID {
                    hoveredID = hovered
                }
            }
            // id 变（包括变成 nil）时旧任务被取消，所以「移开」这一路是同步生效的，
            // 不依赖谁来给 AppKit 发 mouse-exited。
            .task(id: hoveredID) {
                withAnimation(.easeOut(duration: 0.12)) {
                    presentedID = nil
                }
                guard hoveredID != nil else { return }
                do {
                    try await Task.sleep(nanoseconds: Self.showDelay)
                } catch {
                    return  // 被下一次悬停打断
                }
                guard !Task.isCancelled, let id = hoveredID else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    presentedID = id
                }
            }
            .onDisappear {
                // 菜单关掉时 mouse-exit 未必送达。不在这里清，hoveredID 会留在
                // "某某行"，下次点开菜单气泡直接凭空出现 —— 又是一个"该消失
                // 却在"的 tooltip。
                hoveredID = nil
                presentedID = nil
            }
            .overlay {
                GeometryReader { proxy in
                    if let id = presentedID, let anchor = anchors[id] {
                        bubble(for: anchor, in: proxy.size)
                    }
                }
            }
    }

    /// 气泡摆在锚点的哪一侧：默认下方；下面放不下（供应商多、行落在面板下半部）
    /// 就翻到上方硬塞进面板里。宁可换边，也不要半个气泡被面板窗口裁掉 ——
    /// 那个残缺的样子看起来同样像"卡住没消失"。
    ///
    /// 定位只靠"前面垫一段固定高度的空白"来做，不去测气泡自己的高度：高度是
    /// 内容决定的，量不准就得再写一份估算，那个估算迟早和实际排版对不上。
    @ViewBuilder
    private func bubble(for anchor: MenuTooltipAnchor, in size: CGSize) -> some View {
        let estimated = Self.estimatedHeight(for: anchor)
        let fitsBelow = anchor.frame.maxY + 4 + estimated <= size.height - 8
        let row = HStack(spacing: 0) {
            Spacer(minLength: 0)
            MenuTooltipBubble(lines: anchor.lines)
                .frame(maxWidth: Self.maximumWidth)
            Spacer(minLength: 0)
        }
        .frame(width: size.width)
        // GeometryReader 的内容从左上角 (0,0) 起算，和锚点用的是同一个坐标系。
        VStack(spacing: 0) {
            if fitsBelow {
                Color.clear.frame(height: max(0, anchor.frame.maxY + 4))
                row
            } else {
                row
                // 把气泡的下边缘顶到该行上边缘之上。
                Color.clear.frame(height: max(0, size.height - anchor.frame.minY + 4))
            }
        }
        .allowsHitTesting(false)
    }

    private static let maximumWidth: CGFloat = 248

    /// 只用来判断"下方还放不放得下"，不需要精确 —— 差几像素最多让气泡提前
    /// 翻到上面，而翻上去永远比被裁掉好。
    private static func estimatedHeight(for anchor: MenuTooltipAnchor) -> CGFloat {
        CGFloat(anchor.lines.count) * 15 + 14
    }
}

/// 气泡本体。
///
/// `allowsHitTesting(false)` 是必须的，不是保险：气泡压在锚点上方，一旦它能接到
/// 鼠标事件就会把原来的 hover 打断，锚点收到 mouse-exited，气泡会自己把自己关掉
/// —— 于是变成"鼠标还停在那儿，气泡却不见了"。
struct MenuTooltipBubble: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
        .allowsHitTesting(false)
    }
}