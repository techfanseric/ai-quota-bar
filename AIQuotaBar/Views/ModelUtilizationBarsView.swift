import SwiftUI

/// 每个 model 现有图表正下方的"跨周期柱图"。
/// 1 根柱 = 1 个周期（模式决定是否包含当前 in-progress 周期），柱高 = 周期内 peak usedPercent (0-100)。
/// 整体高度 40pt，宽度自适应，仿 codexbar `PlanUtilizationHistoryChartMenuView` 的双层柱视觉。
/// 调用方需自行保证 `cycles` 非空（空时整段不渲染，不要 fallback 到占位）。
struct ModelUtilizationBarsView: View {
    let cycles: [(resetsAt: Date, peakPercent: Double)]
    let cycleLabel: String
    let cycleDuration: TimeInterval?
    let tint: Color
    let isHovered: Bool

    @State private var hoverLocation: CGPoint?

    private static let totalHeight: CGFloat = 40
    private static let labelHeight: CGFloat = 9
    private static let labelSpacing: CGFloat = 2
    private static let topReservedForLabel: CGFloat = 10
    private static let gap: CGFloat = 2
    private static let minBarWidth: CGFloat = 3
    private static let maxBarWidth: CGFloat = 10
    private static let barCornerRadius: CGFloat = 1.5
    private static let barTrackOpacity: Double = 0.07
    private static let topPercentFontSize: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: Self.labelSpacing) {
            Text("\(cycleLabel) · left")
                .font(.system(size: Self.labelHeight))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            GeometryReader { geometry in
                let size = geometry.size

                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        drawBars(context: &context, size: size)
                    }

                    if let hoveredCycle = hoveredCycle(in: size) {
                        CycleCallout(text: cycleHoverText(for: hoveredCycle.index))
                            .position(calloutPosition(for: hoveredCycle.trackRect, size: size))
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoverLocation = location
                    case .ended:
                        hoverLocation = nil
                    }
                }
            }
        }
        .frame(height: Self.totalHeight)
    }

    private func drawBars(context: inout GraphicsContext, size: CGSize) {
        for bar in bars(in: size) {
            let cycle = cycles[bar.index]
            let heightFraction = max(0, min(1, cycle.peakPercent / 100))
            let usedHeight = bar.trackRect.height * CGFloat(heightFraction)
            let barTopY = bar.trackRect.maxY - usedHeight

            // 背景 track
            let trackPath = Path(roundedRect: bar.trackRect, cornerRadius: Self.barCornerRadius)
            context.fill(trackPath, with: .color(Color.primary.opacity(Self.barTrackOpacity)))

            // 已用部分
            if usedHeight > 0 {
                let usedRect = CGRect(x: bar.trackRect.minX, y: barTopY, width: bar.trackRect.width, height: usedHeight)
                let usedPath = Path(roundedRect: usedRect, cornerRadius: Self.barCornerRadius)
                context.fill(usedPath, with: .color(tint))
            }

            // 柱顶百分比：柱高 = 周期内 peak used%，label 显示对应的 left 额度（100 - used），
            // 与 codexbar `PlanUtilizationHistoryChartMenuView` 语义对齐 —— "用剩多少"。
            if isHovered {
                let leftPercent = max(0, min(100, 100 - cycle.peakPercent))
                let label = context.resolve(
                    Text("\(Int(leftPercent.rounded()))")
                        .font(.system(size: Self.topPercentFontSize))
                        .foregroundColor(.secondary)
                )
                let labelX = bar.trackRect.midX
                let labelBottomY = max(bar.trackRect.minY + Self.topPercentFontSize + 1, barTopY - 1)
                context.draw(label, at: CGPoint(x: labelX, y: labelBottomY), anchor: .bottom)
            }
        }
    }

    private var n: Int {
        cycles.count
    }

    private func bars(in size: CGSize) -> [CycleBar] {
        guard n > 0 else { return [] }

        let plotTop: CGFloat = Self.topReservedForLabel
        let plotBottom: CGFloat = size.height
        let plotWidth: CGFloat = size.width
        let plotHeight = max(plotBottom - plotTop, 0)

        let totalGapWidth = Self.gap * CGFloat(max(n - 1, 0))
        let barWidth = min(Self.maxBarWidth, max(Self.minBarWidth, (plotWidth - totalGapWidth) / CGFloat(n)))
        let totalBarsWidth = barWidth * CGFloat(n) + totalGapWidth
        let startX = (plotWidth - totalBarsWidth) / 2

        return cycles.indices.map { index in
            let x = startX + CGFloat(index) * (barWidth + Self.gap)
            let trackRect = CGRect(x: x, y: plotTop, width: barWidth, height: plotHeight)
            return CycleBar(index: index, trackRect: trackRect)
        }
    }

    private func hoveredCycle(in size: CGSize) -> CycleBar? {
        guard let hoverLocation else { return nil }
        let bars = bars(in: size)
        guard !bars.isEmpty else { return nil }

        let plotRect = CGRect(
            x: 0,
            y: Self.topReservedForLabel,
            width: size.width,
            height: max(size.height - Self.topReservedForLabel, 0)
        )
        guard plotRect.insetBy(dx: -4, dy: -6).contains(hoverLocation) else { return nil }

        if let directHit = bars.first(where: { $0.trackRect.insetBy(dx: 2, dy: 6).contains(hoverLocation) }) {
            return directHit
        }

        return bars.min { lhs, rhs in
            abs(lhs.trackRect.midX - hoverLocation.x) < abs(rhs.trackRect.midX - hoverLocation.x)
        }
    }

    private func calloutPosition(for barRect: CGRect, size: CGSize) -> CGPoint {
        let tooltipWidth: CGFloat = 168
        let x = min(max(barRect.midX, tooltipWidth / 2), size.width - tooltipWidth / 2)
        return CGPoint(x: x, y: 6)
    }

    private func cycleHoverText(for index: Int) -> String {
        guard cycles.indices.contains(index) else { return "" }
        let leftPercent = max(0, min(100, 100 - cycles[index].peakPercent))
        return "\(cycleTimeRangeText(for: index)) · \(Int(leftPercent.rounded()))%"
    }

    private func cycleTimeRangeText(for index: Int) -> String {
        let end = cycles[index].resetsAt
        let start = cycleStart(for: index, end: end)
        return compactTimeRangeText(from: start, to: end)
    }

    private func cycleStart(for index: Int, end: Date) -> Date {
        if cycles.indices.contains(index + 1) {
            return cycles[index + 1].resetsAt
        }

        let inferredDuration: TimeInterval
        if let cycleDuration, cycleDuration > 0 {
            inferredDuration = cycleDuration
        } else if cycles.indices.contains(index - 1) {
            inferredDuration = cycles[index - 1].resetsAt.timeIntervalSince(end)
        } else {
            inferredDuration = 0
        }

        return end.addingTimeInterval(-max(inferredDuration, 0))
    }

    private func compactTimeRangeText(from start: Date, to end: Date) -> String {
        let calendar = Calendar.current
        let startTime = timeText(start)
        let endTime = timeText(end)

        if calendar.isDate(start, inSameDayAs: end) {
            if calendar.isDateInToday(start) || calendar.isDateInYesterday(start) {
                return "\(startTime)-\(endTime)"
            }
            return "\(dateText(start)) \(startTime)-\(endTime)"
        }

        return "\(compactDateTimeText(start))-\(compactDateTimeText(end))"
    }

    private func compactDateTimeText(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) || Calendar.current.isDateInYesterday(date) {
            return timeText(date)
        }
        return "\(dateText(date)) \(timeText(date))"
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = .current
        formatter.locale = .current
        formatter.dateFormat = "MM/dd"
        return formatter.string(from: date)
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = .current
        formatter.locale = .current
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

private struct CycleBar {
    let index: Int
    let trackRect: CGRect
}

private struct CycleCallout: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}
