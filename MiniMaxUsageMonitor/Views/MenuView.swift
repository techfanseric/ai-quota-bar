import AppKit
import SwiftUI

struct MenuView: View {
    @ObservedObject var viewModel: UsageViewModel
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerCard
            detailCard
            actionsCard
        }
        .padding(14)
        .frame(width: 340)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .controlBackgroundColor)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var language: AppLanguage {
        viewModel.appLanguage
    }

    private var usageTint: Color {
        guard let percentage = viewModel.usageData?.percentageRemaining else {
            return viewModel.error == nil ? .accentColor : .orange
        }

        switch percentage {
        case ..<20:
            return .red
        case ..<50:
            return .orange
        default:
            return .green
        }
    }

    private var primaryValueColor: Color {
        viewModel.usageData?.percentageRemaining ?? 0 < viewModel.warningThreshold ? .primary : usageTint
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
                            Text("\(Int(data.percentageRemaining))")
                                .font(.system(size: 38, weight: .bold, design: .rounded))
                                .foregroundStyle(primaryValueColor)
                            Text(language.text(.percentLeft))
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }

                        ProgressView(value: data.percentageRemaining, total: 100)
                            .tint(usageTint)
                            .controlSize(.large)

                        HStack(spacing: 10) {
                            MetricChip(title: language.text(.remaining), value: "\(data.remains)")
                            MetricChip(title: language.text(.total), value: "\(data.total)")
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
                    SummaryRow(title: language.text(.remainingQuota), value: "\(data.remains)")
                    SummaryRow(title: language.text(.usageRatio), value: language.availablePercentageText(Int(data.percentageRemaining)))
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
        if let percentage = viewModel.usageData?.percentageRemaining {
            return percentage < viewModel.warningThreshold ? language.text(.statusLowQuota) : language.text(.statusHealthy)
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

        if let percentage = viewModel.usageData?.percentageRemaining {
            return percentage < viewModel.warningThreshold
                ? language.text(.statusApproachingThreshold)
                : language.text(.statusStable)
        }

        return language.text(.statusWaitingFirstRefresh)
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
                .font(.system(size: 16, weight: .semibold, design: .rounded))
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
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
