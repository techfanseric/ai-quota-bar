import AppKit
import SwiftUI

struct MenuView: View {
    @ObservedObject var viewModel: UsageViewModel
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            modelsList
            Divider()
                .padding(.vertical, 4)
            footer
        }
        .padding(10)
        .frame(width: 280)
    }

    private var language: AppLanguage {
        viewModel.appLanguage
    }

    @ViewBuilder
    private var modelsList: some View {
        if let data = viewModel.usageData, !data.models.isEmpty {
            let sorted = data.models.sorted { lhs, rhs in
                // Sort by usage percentage descending (more used first)
                lhs.currentIntervalPercentageUsed > rhs.currentIntervalPercentageUsed
            }

            VStack(spacing: 0) {
                // Header
                HStack(spacing: 8) {
                    Text("\(data.modelCount) models")
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

                ForEach(Array(sorted.enumerated()), id: \.element.id) { index, model in
                    ModelRow(
                        model: model,
                        language: language,
                        warningThreshold: viewModel.warningThreshold
                    )

                    if index < sorted.count - 1 {
                        Spacer()
                            .frame(height: 1)
                    }
                }
            }
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

private struct ModelRow: View {
    let model: ModelUsageData
    let language: AppLanguage
    let warningThreshold: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top row: name + remaining count
            HStack(spacing: 8) {
                Text(model.modelName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                Spacer()

                Text("\(model.currentIntervalRemaining)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
            }

            // Progress bar (showing usage)
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

            // Bottom row: reset time + weekly (if any) + used/total
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
