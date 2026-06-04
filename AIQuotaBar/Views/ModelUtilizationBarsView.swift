import SwiftUI

/// 每个 model 现有图表正下方的"跨周期柱图"。
/// 1 根柱 = 1 个周期（模式决定是否包含当前 in-progress 周期），柱高 = 周期内 peak usedPercent (0-100)。
/// 整体高度 40pt，宽度自适应，仿 codexbar `PlanUtilizationHistoryChartMenuView` 的双层柱视觉。
/// 调用方需自行保证 `cycles` 非空（空时整段不渲染，不要 fallback 到占位）。
struct ModelUtilizationBarsView: View {
    let cycles: [(resetsAt: Date, peakPercent: Double)]
    let cycleLabel: String
    let tint: Color
    let isHovered: Bool

    private static let totalHeight: CGFloat = 40
    private static let labelHeight: CGFloat = 9
    private static let labelSpacing: CGFloat = 2
    private static let topReservedForLabel: CGFloat = 10
    private static let gap: CGFloat = 2
    private static let minBarWidth: CGFloat = 3
    private static let maxBarWidth: CGFloat = 10
    private static let barCornerRadius: CGFloat = 1.5
    private static let barTrackOpacity: Double = 0.07
    private static let topPercentFontSize: CGFloat = 7

    var body: some View {
        VStack(alignment: .leading, spacing: Self.labelSpacing) {
            Text(cycleLabel)
                .font(.system(size: Self.labelHeight))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Canvas { context, size in
                drawBars(context: &context, size: size)
            }
        }
        .frame(height: Self.totalHeight)
    }

    private func drawBars(context: inout GraphicsContext, size: CGSize) {
        let plotTop: CGFloat = Self.topReservedForLabel
        let plotBottom: CGFloat = size.height
        let plotWidth: CGFloat = size.width
        let plotHeight = max(plotBottom - plotTop, 0)

        let n = cycles.count
        let totalGapWidth = Self.gap * CGFloat(max(n - 1, 0))
        let barWidth = min(Self.maxBarWidth, max(Self.minBarWidth, (plotWidth - totalGapWidth) / CGFloat(n)))
        let totalBarsWidth = barWidth * CGFloat(n) + totalGapWidth
        let startX = (plotWidth - totalBarsWidth) / 2

        let showLabels = n <= 12

        for (index, cycle) in cycles.enumerated() {
            let x = startX + CGFloat(index) * (barWidth + Self.gap)
            let heightFraction = max(0, min(1, cycle.peakPercent / 100))
            let usedHeight = plotHeight * CGFloat(heightFraction)
            let barTopY = plotBottom - usedHeight

            // 背景 track
            let trackRect = CGRect(x: x, y: plotTop, width: barWidth, height: plotHeight)
            let trackPath = Path(roundedRect: trackRect, cornerRadius: Self.barCornerRadius)
            context.fill(trackPath, with: .color(Color.primary.opacity(Self.barTrackOpacity)))

            // 已用部分
            if usedHeight > 0 {
                let usedRect = CGRect(x: x, y: barTopY, width: barWidth, height: usedHeight)
                let usedPath = Path(roundedRect: usedRect, cornerRadius: Self.barCornerRadius)
                context.fill(usedPath, with: .color(tint))
            }

            // 柱顶百分比（N ≤ 12 才显示，避免重叠；hover 时才出现）
            if showLabels, isHovered {
                let label = context.resolve(
                    Text("\(Int(cycle.peakPercent.rounded()))%")
                        .font(.system(size: Self.topPercentFontSize))
                        .foregroundColor(.secondary)
                )
                let labelX = x + barWidth / 2
                let labelBottomY = max(plotTop + Self.topPercentFontSize + 1, barTopY - 1)
                context.draw(label, at: CGPoint(x: labelX, y: labelBottomY), anchor: .bottom)
            }
        }
    }
}
