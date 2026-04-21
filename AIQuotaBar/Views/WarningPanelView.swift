import SwiftUI

struct WarningPanelView: View {
    let usageData: UsageData
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.title2)
                Text(language.text(.warningPanelTitle))
                    .font(.headline)
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(language.text(.models))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(language.modelsReadyHeadline(ready: usageData.readyModelsCount, total: usageData.modelCount))
                        .fontWeight(.bold)
                }

                HStack {
                    Text(language.text(.mostUrgent))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(mostUrgentSummary)
                        .fontWeight(.medium)
                }

                HStack {
                    Text(language.text(.nextReset))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(nextResetSummary)
                        .fontWeight(.medium)
                }
            }
            .font(.caption)
        }
        .padding(16)
        .frame(width: 280)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var mostUrgentSummary: String {
        guard let model = usageData.mostUrgentModel else {
            return "—"
        }

        if !model.isCurrentIntervalAvailable {
            return "\(model.modelName) · \(language.fullStatusText())"
        }

        return "\(model.modelName) · \(language.unitsLeftText(model.currentIntervalRemaining))"
    }

    private var nextResetSummary: String {
        guard let nextReset = usageData.nextResetDate else {
            return "—"
        }

        return language.relativeText(until: nextReset)
    }
}
