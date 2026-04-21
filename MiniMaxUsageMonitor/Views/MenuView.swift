import AppKit
import SwiftUI

struct MenuView: View {
    @ObservedObject var viewModel: UsageViewModel
    var onOpenSettings: () -> Void
    var onLayoutChange: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                modelsList
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 540)

            Divider()
                .padding(.vertical, 4)
            footer
        }
        .padding(10)
        .frame(width: 296)
    }

    private var language: AppLanguage {
        viewModel.appLanguage
    }

    @ViewBuilder
    private var modelsList: some View {
        let sections = viewModel.providerUsageSections
        if !sections.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("\(sections.count) providers · \(sections.map(\.modelCount).reduce(0, +)) models")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Image(systemName: viewModel.isLoading ? "hourglass" : "arrow.clockwise")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isLoading)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 8)

                ForEach(sections, id: \.provider) { data in
                    ProviderModelsSection(
                        data: data,
                        language: language,
                        warningThreshold: viewModel.warningThreshold,
                        samples: viewModel.samples(for:),
                        onLayoutChange: onLayoutChange
                    )
                }

                if !viewModel.providerErrors.isEmpty {
                    Divider()
                        .padding(.vertical, 4)

                    ForEach(UsageProvider.allCases.filter { viewModel.providerErrors[$0] != nil }) { provider in
                        if let error = viewModel.providerErrors[provider] {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("\(provider.displayName): \(language.errorDescription(for: error))")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        } else if !viewModel.hasAPIKey {
            MenuPlaceholderCard(
                icon: "key.fill",
                title: language.text(.errorNotConfigured),
                message: language.text(.menuConfigureKeyHint),
                primaryActionTitle: language.text(.settings),
                primaryAction: onOpenSettings
            )
        } else if viewModel.isLoading || (viewModel.usageData == nil && viewModel.error == nil) {
            MenuPlaceholderCard(
                icon: "hourglass",
                title: language.text(.loading),
                message: language.text(.menuLoadingHint),
                showsSpinner: true
            )
        } else if let error = viewModel.error {
            MenuPlaceholderCard(
                icon: "exclamationmark.triangle.fill",
                title: language.errorDescription(for: error),
                message: language.text(.menuRefreshHint),
                primaryActionTitle: language.text(.refresh),
                primaryAction: {
                    Task { await viewModel.refresh() }
                },
                secondaryActionTitle: language.text(.settings),
                secondaryAction: onOpenSettings
            )
        } else {
            MenuPlaceholderCard(
                icon: "tray.fill",
                title: language.text(.models),
                message: language.text(.menuEmptyModelsHint),
                primaryActionTitle: language.text(.refresh),
                primaryAction: {
                    Task { await viewModel.refresh() }
                }
            )
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button(action: onOpenSettings) {
                Text("Settings")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }
}

private struct MenuPlaceholderCard: View {
    let icon: String
    let title: String
    let message: String
    var primaryActionTitle: String? = nil
    var primaryAction: (() -> Void)? = nil
    var secondaryActionTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil
    var showsSpinner: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: 28, height: 28)

                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)

                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if showsSpinner {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if primaryActionTitle != nil || secondaryActionTitle != nil {
                HStack(spacing: 8) {
                    if let primaryActionTitle, let primaryAction {
                        Button(action: primaryAction) {
                            Text(primaryActionTitle)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }

                    if let secondaryActionTitle, let secondaryAction {
                        Button(action: secondaryAction) {
                            Text(secondaryActionTitle)
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

private struct ProviderModelsSection: View {
    let data: UsageData
    let language: AppLanguage
    let warningThreshold: Double
    let samples: (ModelUsageData) -> [ModelQuotaSample]
    let onLayoutChange: () -> Void

    @State private var showsFullQuotaModels = false

    private var visibleModels: [ModelUsageData] {
        data.models.sorted { lhs, rhs in
            lhs.currentIntervalPercentageUsed > rhs.currentIntervalPercentageUsed
        }.filter {
            !$0.isFullQuotaUnused
        }
    }

    private var fullQuotaModels: [ModelUsageData] {
        data.models.sorted { lhs, rhs in
            lhs.modelName < rhs.modelName
        }.filter {
            $0.isFullQuotaUnused
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(data.provider.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(language.menuBarCompactText(ready: data.readyModelsCount, total: data.modelCount))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)

            ForEach(Array(visibleModels.enumerated()), id: \.element.id) { index, model in
                ModelRow(
                    model: model,
                    language: language,
                    warningThreshold: warningThreshold,
                    samples: samples(model)
                )

                if index < visibleModels.count - 1 {
                    Spacer()
                        .frame(height: 1)
                }
            }

            if visibleModels.isEmpty && !fullQuotaModels.isEmpty && !showsFullQuotaModels {
                Text(language.allModelsUnusedText())
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }

            if !fullQuotaModels.isEmpty {
                Button {
                    showsFullQuotaModels.toggle()
                    DispatchQueue.main.async {
                        onLayoutChange()
                        DispatchQueue.main.async {
                            onLayoutChange()
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showsFullQuotaModels ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 10)

                        Text(language.fullQuotaModelsToggleText(count: fullQuotaModels.count, isExpanded: showsFullQuotaModels))
                            .font(.system(size: 10, weight: .medium))

                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)

                if showsFullQuotaModels {
                    ForEach(Array(fullQuotaModels.enumerated()), id: \.element.id) { index, model in
                        ModelRow(
                            model: model,
                            language: language,
                            warningThreshold: warningThreshold,
                            samples: samples(model)
                        )

                        if index < fullQuotaModels.count - 1 {
                            Spacer()
                                .frame(height: 1)
                        }
                    }
                }
            }
        }
    }
}

private struct ModelRow: View {
    let model: ModelUsageData
    let language: AppLanguage
    let warningThreshold: Double
    let samples: [ModelQuotaSample]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(model.modelName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                Spacer()

                Text("\(model.currentIntervalRemaining)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
            }

            if model.isShortCurrentInterval {
                QuotaAreaChart(
                    model: model,
                    samples: samples,
                    tint: tint
                )
                .frame(height: 84)
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 5)

                        if model.currentIntervalPercentageUsed > 0 {
                            Capsule()
                                .fill(tint)
                                .frame(width: geo.size.width * model.currentIntervalPercentageUsed / 100, height: 5)
                        }
                    }
                }
                .frame(height: 5)
            }

            HStack(spacing: 8) {
                Text(model.resetTimeText)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)

                if model.hasWeeklyLimit {
                    Text("·")
                        .foregroundStyle(.tertiary)

                    if model.isWeeklyFull {
                        Text(language.weeklyUnusedText())
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("周 \(model.weeklyRemaining)/\(model.weeklyTotal)")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text("\(model.currentIntervalUsedCount)/\(model.currentIntervalTotal)")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    private var tint: Color {
        if model.currentIntervalPercentageUsed >= 100 { return .red }
        if model.currentIntervalPercentageUsed >= 80 { return .orange }
        if model.currentIntervalUsedCount > 0 && model.currentIntervalPercentageRemaining <= warningThreshold { return .orange }
        if model.currentIntervalUsedCount > 0 { return .green }
        return .secondary
    }
}

private struct QuotaAreaChart: View {
    let model: ModelUsageData
    let samples: [ModelQuotaSample]
    let tint: Color

    @State private var hoverLocation: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let layout = QuotaChartLayout(size: geometry.size)

            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawBackground(context: &context, layout: layout)
                    drawAxes(context: &context, layout: layout)
                    drawSeries(context: &context, layout: layout)
                    drawHoveredGuide(context: &context, layout: layout)
                }

                if let hoveredSample = hoveredSample(in: layout) {
                    ChartCallout(text: hoverText(for: hoveredSample))
                        .position(calloutPosition(for: hoveredSample, layout: layout))
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

    private func drawBackground(context: inout GraphicsContext, layout: QuotaChartLayout) {
        let rect = RoundedRectangle(cornerRadius: 7, style: .continuous).path(in: layout.plotRect)
        context.fill(rect, with: .color(Color.primary.opacity(0.035)))
    }

    private func drawAxes(context: inout GraphicsContext, layout: QuotaChartLayout) {
        var axisPath = Path()
        axisPath.move(to: CGPoint(x: layout.plotRect.minX, y: layout.plotRect.minY))
        axisPath.addLine(to: CGPoint(x: layout.plotRect.minX, y: layout.plotRect.maxY))
        axisPath.addLine(to: CGPoint(x: layout.plotRect.maxX, y: layout.plotRect.maxY))
        context.stroke(axisPath, with: .color(Color.primary.opacity(0.14)), lineWidth: 1)

        let midY = yPosition(forRemaining: Double(model.currentIntervalTotal) / 2, layout: layout)
        var midline = Path()
        midline.move(to: CGPoint(x: layout.plotRect.minX, y: midY))
        midline.addLine(to: CGPoint(x: layout.plotRect.maxX, y: midY))
        context.stroke(midline, with: .color(Color.primary.opacity(0.06)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        context.draw(axisLabel("\(model.currentIntervalTotal)"), at: CGPoint(x: layout.leftAxisLabelX, y: layout.plotRect.minY), anchor: .leading)
        context.draw(axisLabel("0"), at: CGPoint(x: layout.leftAxisLabelX, y: layout.plotRect.maxY), anchor: .leading)

        if let startTime = model.startTime, let endTime = model.endTime {
            context.draw(axisLabel(axisTimeText(for: startTime)), at: CGPoint(x: layout.plotRect.minX, y: layout.axisLabelY), anchor: .topLeading)
            context.draw(axisLabel(axisTimeText(for: endTime)), at: CGPoint(x: layout.plotRect.maxX, y: layout.axisLabelY), anchor: .topTrailing)
        }
    }

    private func drawSeries(context: inout GraphicsContext, layout: QuotaChartLayout) {
        let points = plottedSamples(in: layout)
        guard !points.isEmpty else { return }

        if points.count == 1, let point = points.first {
            var guide = Path()
            guide.move(to: CGPoint(x: point.x, y: layout.plotRect.maxY))
            guide.addLine(to: point)
            context.stroke(guide, with: .color(tint.opacity(0.45)), lineWidth: 2)

            let markerRect = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
            context.fill(Path(ellipseIn: markerRect), with: .color(tint))
            return
        }

        guard let firstPoint = points.first,
              let lastPoint = points.last else { return }

        var areaPath = Path()
        areaPath.move(to: CGPoint(x: firstPoint.x, y: layout.plotRect.maxY))  // Y1=0
        areaPath.addLine(to: CGPoint(x: firstPoint.x, y: firstPoint.y))       // 到第一个点
        areaPath.addLines(points)                                              // 沿曲线到最后一个点
        areaPath.addLine(to: CGPoint(x: lastPoint.x, y: layout.plotRect.maxY)) // Yn=0
        areaPath.addLine(to: CGPoint(x: firstPoint.x, y: layout.plotRect.maxY)) // 回到 Y1=0
        areaPath.closeSubpath()
        context.fill(
            areaPath,
            with: .linearGradient(
                Gradient(colors: [
                    tint.opacity(0.22),
                    tint.opacity(0.03)
                ]),
                startPoint: CGPoint(x: 0, y: layout.plotRect.minY),
                endPoint: CGPoint(x: 0, y: layout.plotRect.maxY)
            )
        )

        var linePath = Path()
        linePath.addLines(points)
        context.stroke(
            linePath,
            with: .color(tint),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        )

        for point in points {
            let markerRect = CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)
            context.fill(Path(ellipseIn: markerRect), with: .color(tint))
        }
    }

    private func drawHoveredGuide(context: inout GraphicsContext, layout: QuotaChartLayout) {
        guard let hoveredSample = hoveredSample(in: layout) else { return }

        let point = plottedPoint(for: hoveredSample, layout: layout)

        var guide = Path()
        guide.move(to: CGPoint(x: point.x, y: layout.plotRect.minY))
        guide.addLine(to: CGPoint(x: point.x, y: layout.plotRect.maxY))
        context.stroke(guide, with: .color(tint.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

        let markerRect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
        context.fill(Path(ellipseIn: markerRect), with: .color(.white))
        context.stroke(Path(ellipseIn: markerRect), with: .color(tint), lineWidth: 2)
    }

    private func plottedSamples(in layout: QuotaChartLayout) -> [CGPoint] {
        samples
            .sorted { $0.timestamp < $1.timestamp }
            .map { plottedPoint(for: $0, layout: layout) }
    }

    private func plottedPoint(for sample: ModelQuotaSample, layout: QuotaChartLayout) -> CGPoint {
        CGPoint(
            x: xPosition(for: sample.timestamp, layout: layout),
            y: yPosition(forRemaining: Double(sample.remaining), layout: layout)
        )
    }

    private func xPosition(for date: Date, layout: QuotaChartLayout) -> CGFloat {
        guard let startTime = model.startTime, let endTime = model.endTime else {
            return layout.plotRect.minX
        }

        let totalDuration = max(endTime.timeIntervalSince(startTime), 1)
        let elapsed = min(max(date.timeIntervalSince(startTime), 0), totalDuration)
        let ratio = elapsed / totalDuration
        return layout.plotRect.minX + layout.plotRect.width * ratio
    }

    private func yPosition(forRemaining remaining: Double, layout: QuotaChartLayout) -> CGFloat {
        guard model.currentIntervalTotal > 0 else { return layout.plotRect.maxY }
        let clampedRemaining = min(max(remaining, 0), Double(model.currentIntervalTotal))
        let ratio = clampedRemaining / Double(model.currentIntervalTotal)
        return layout.plotRect.maxY - layout.plotRect.height * ratio
    }

    private func hoveredSample(in layout: QuotaChartLayout) -> ModelQuotaSample? {
        guard let hoverLocation,
              layout.plotRect.insetBy(dx: -8, dy: -8).contains(hoverLocation),
              !samples.isEmpty else {
            return nil
        }

        return samples.min { lhs, rhs in
            abs(xPosition(for: lhs.timestamp, layout: layout) - hoverLocation.x) <
                abs(xPosition(for: rhs.timestamp, layout: layout) - hoverLocation.x)
        }
    }

    private func hoverText(for sample: ModelQuotaSample) -> String {
        "\(tooltipTimeText(for: sample.timestamp)) · \(sample.remaining)"
    }

    private func calloutPosition(for sample: ModelQuotaSample, layout: QuotaChartLayout) -> CGPoint {
        let point = plottedPoint(for: sample, layout: layout)
        let tooltipWidth: CGFloat = 120
        let x = min(max(point.x, tooltipWidth / 2), layout.size.width - tooltipWidth / 2)
        let y = max(point.y - 18, 12)
        return CGPoint(x: x, y: y)
    }

    private func axisLabel(_ text: String) -> Text {
        Text(text)
            .font(.system(size: 9, design: .rounded))
            .foregroundStyle(.secondary)
    }

    private func axisTimeText(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = .current
        formatter.locale = .current

        if let startTime = model.startTime,
           Calendar.current.isDate(date, inSameDayAs: startTime) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "MM/dd HH:mm"
        }

        return formatter.string(from: date)
    }

    private func tooltipTimeText(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = .current
        formatter.locale = .current
        formatter.dateFormat = "MM/dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

private struct QuotaChartLayout {
    let size: CGSize

    private let leftInset: CGFloat = 30
    private let rightInset: CGFloat = 8
    private let topInset: CGFloat = 8
    private let bottomInset: CGFloat = 18

    var plotRect: CGRect {
        CGRect(
            x: leftInset,
            y: topInset,
            width: max(size.width - leftInset - rightInset, 1),
            height: max(size.height - topInset - bottomInset, 1)
        )
    }

    var leftAxisLabelX: CGFloat {
        3
    }

    var axisLabelY: CGFloat {
        plotRect.maxY + 4
    }
}

private struct ChartCallout: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}
