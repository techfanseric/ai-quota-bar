import AppKit
import SwiftUI

struct MenuView: View {
    @ObservedObject var viewModel: UsageViewModel
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerCard
            detailCard
            modelsCard
            actionsCard
        }
        .padding(14)
        .frame(width: 352)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var language: AppLanguage {
        viewModel.appLanguage
    }

    private var usageTint: Color {
        guard let data = viewModel.usageData else {
            return viewModel.error == nil ? .accentColor : .orange
        }

        if data.exhaustedModelsCount > 0 || data.weeklyExhaustedModelsCount > 0 {
            return .red
        }

        if data.lowModelsCount(threshold: viewModel.warningThreshold) > 0 {
            return .orange
        }

        return .green
    }

    private var primaryValueColor: Color {
        usageTint
    }

    @ViewBuilder
    private var headerCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(language.text(.menuTitle))
                            .font(.system(size: 15, weight: .semibold))

                        Text(statusSubtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    StatusCapsule(label: statusLabel, tint: usageTint)
                }

                if let data = viewModel.usageData {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .lastTextBaseline, spacing: 6) {
                            Text(language.modelsReadyHeadline(ready: data.readyModelsCount, total: data.modelCount))
                                .font(.system(size: 38, weight: .bold, design: .rounded))
                                .foregroundStyle(primaryValueColor)
                            Text(language.readyLabel())
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }

                        Text(language.modelsReadyCaption(ready: data.readyModelsCount, total: data.modelCount))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        ProgressView(value: Double(data.readyModelsCount), total: Double(max(data.modelCount, 1)))
                            .tint(usageTint)
                            .controlSize(.large)

                        HStack(spacing: 10) {
                            MetricChip(title: language.readyLabel(), value: "\(data.readyModelsCount)")
                            MetricChip(title: language.fullLabel(), value: "\(data.exhaustedModelsCount)")
                            MetricChip(title: language.weeklyFullLabel(), value: "\(data.weeklyExhaustedModelsCount)")
                        }
                    }
                } else if let usageError = viewModel.error {
                    Label {
                        Text(language.errorDescription(for: usageError))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(language.text(.checkingQuota))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var detailCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(language.text(.details))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                if let data = viewModel.usageData {
                    SummaryRow(
                        title: language.text(.models),
                        value: language.availabilitySummary(ready: data.readyModelsCount, full: data.exhaustedModelsCount)
                    )
                    SummaryRow(title: language.text(.modelCount), value: "\(data.modelCount)")
                    SummaryRow(title: language.text(.nextReset), value: nextResetValue(for: data))
                    SummaryRow(title: language.text(.mostUrgent), value: mostUrgentValue(for: data))
                    SummaryRow(title: language.text(.menuBarStyle), value: viewModel.displayFormat.title(language: language))
                } else if viewModel.error != nil {
                    SummaryRow(title: language.text(.connection), value: language.text(.needsAttention))
                } else {
                    SummaryRow(title: language.text(.connection), value: language.text(.loading))
                }

                if let lastRefresh = viewModel.lastRefreshTime {
                    Divider()
                    HStack {
                        Text(language.text(.lastUpdated))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(lastRefresh, style: .relative)
                            .font(.system(size: 12, weight: .medium))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var modelsCard: some View {
        if let data = viewModel.usageData, !data.models.isEmpty {
            let availableModels = data.models.filter { $0.isCurrentIntervalAvailable }
                .sorted { $0.currentIntervalPercentageRemaining < $1.currentIntervalPercentageRemaining }
            let exhaustedModels = data.models.filter { !$0.isCurrentIntervalAvailable }
                .sorted { $0.currentIntervalPercentageRemaining < $1.currentIntervalPercentageRemaining }

            PanelCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(language.text(.models))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    // Available models first (sorted by percentage remaining, lowest first)
                    ForEach(availableModels) { model in
                        ModelUsageRow(
                            model: model,
                            language: language,
                            warningThreshold: viewModel.warningThreshold
                        )

                        if model.id != availableModels.last?.id {
                            Divider()
                        }
                    }

                    // Collapsed section for exhausted models
                    if !exhaustedModels.isEmpty {
                        CollapsibleSection(
                            title: language.fullModelsText(exhaustedModels.count),
                            count: exhaustedModels.count
                        ) {
                            ForEach(exhaustedModels) { model in
                                ModelUsageRow(
                                    model: model,
                                    language: language,
                                    warningThreshold: viewModel.warningThreshold
                                )

                                if model.id != exhaustedModels.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var actionsCard: some View {
        PanelCard {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        Task {
                            await viewModel.refresh()
                        }
                    } label: {
                        Label(language.text(.refresh), systemImage: viewModel.isLoading ? "hourglass" : "arrow.clockwise")
                    }
                    .buttonStyle(MenuActionButtonStyle(tint: .accentColor))
                    .disabled(viewModel.isLoading)

                    Button(action: onOpenSettings) {
                        Label(language.text(.settings), systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(MenuActionButtonStyle(tint: .secondary))
                }

                Button(role: .destructive) {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label(language.text(.quitApp), systemImage: "power")
                }
                .buttonStyle(MenuActionButtonStyle(tint: .red, fill: true))
            }
        }
    }

    private var statusLabel: String {
        if viewModel.isLoading { return language.text(.statusRefreshing) }
        if viewModel.error != nil { return language.text(.statusAttention) }
        if let data = viewModel.usageData {
            let hasRisk =
                data.exhaustedModelsCount > 0 ||
                data.weeklyExhaustedModelsCount > 0 ||
                data.lowModelsCount(threshold: viewModel.warningThreshold) > 0
            return hasRisk ? language.text(.statusLowQuota) : language.text(.statusHealthy)
        }
        return language.text(.statusChecking)
    }

    private var statusSubtitle: String {
        if viewModel.isLoading {
            return language.text(.statusFetchingSnapshot)
        }

        if let usageError = viewModel.error {
            return language.errorDescription(for: usageError)
        }

        if let data = viewModel.usageData {
            if data.exhaustedModelsCount > 0 {
                return language.fullModelsText(data.exhaustedModelsCount)
            }

            if data.weeklyExhaustedModelsCount > 0 {
                return language.weeklyFullModelsText(data.weeklyExhaustedModelsCount)
            }

            let lowModels = data.lowModelsCount(threshold: viewModel.warningThreshold)
            if lowModels > 0 {
                return language.lowModelsText(lowModels)
            }

            return language.modelsReadyCaption(ready: data.readyModelsCount, total: data.modelCount)
        }

        return language.text(.statusWaitingFirstRefresh)
    }

    private func nextResetValue(for data: UsageData) -> String {
        guard let nextReset = data.nextResetDate else {
            return "—"
        }

        return language.relativeText(until: nextReset)
    }

    private func mostUrgentValue(for data: UsageData) -> String {
        guard let model = data.mostUrgentModel else {
            return "—"
        }

        if !model.isCurrentIntervalAvailable {
            return "\(model.modelName) · \(language.fullStatusText())"
        }

        return "\(model.modelName) · \(language.unitsLeftText(model.currentIntervalRemaining))"
    }
}

private struct ModelUsageRow: View {
    let model: ModelUsageData
    let language: AppLanguage
    let warningThreshold: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.modelName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)

                Spacer()

                ModelStateBadge(
                    title: badgeTitle,
                    tint: badgeTint
                )
            }

            Text(metadataLine)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var badgeTitle: String {
        if !model.isCurrentIntervalAvailable {
            return language.fullStatusText()
        }

        return language.unitsLeftText(model.currentIntervalRemaining)
    }

    private var badgeTint: Color {
        if !model.isCurrentIntervalAvailable {
            return .red
        }

        if model.currentIntervalPercentageRemaining <= warningThreshold {
            return .orange
        }

        return .green
    }

    private var metadataLine: String {
        var parts = [
            language.remainingUsageCompact(
                remaining: model.currentIntervalRemaining,
                total: model.currentIntervalTotal
            )
        ]

        if model.hasWeeklyLimit {
            parts.append(
                language.weeklyUsageCompact(
                    weeklyUsed: model.weeklyUsed,
                    weeklyTotal: model.weeklyTotal
                )
            )
        } else {
            parts.append(language.text(.noWeeklyCap))
        }

        if let endTime = model.endTime {
            parts.append("\(language.text(.nextReset)) \(language.relativeText(until: endTime))")
        }

        return parts.joined(separator: " · ")
    }
}

private struct PanelCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct StatusCapsule: View {
    let label: String
    let tint: Color

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.14))
            )
    }
}

private struct MetricChip: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

private struct ModelStateBadge: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.12))
            )
    }
}

private struct SummaryRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct CollapsibleSection<Content: View>: View {
    let title: String
    let count: Int
    @ViewBuilder let content: () -> Content
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)

                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )
                }
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .padding(.vertical, 8)

                content()
            }
        }
    }
}

private struct MenuActionButtonStyle: ButtonStyle {
    let tint: Color
    var fill: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(fill ? Color.white : tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(borderColor, lineWidth: fill ? 0 : 1)
            )
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if fill {
            return tint.opacity(isPressed ? 0.8 : 0.95)
        }
        return tint.opacity(isPressed ? 0.16 : 0.10)
    }

    private var borderColor: Color {
        tint.opacity(0.22)
    }
}
