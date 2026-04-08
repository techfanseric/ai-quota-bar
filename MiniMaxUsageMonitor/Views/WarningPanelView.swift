import SwiftUI

struct WarningPanelView: View {
    let usageData: UsageData
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    Text(language.text(.warningRemaining))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(usageData.remains) (\(Int(usageData.percentageRemaining))%)")
                        .fontWeight(.bold)
                }

                HStack {
                    Text(language.text(.warningTime))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(usageData.timestamp, style: .time)
                }

                HStack {
                    Text(language.text(.warningEstExhaustion))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(estimatedExhaustion)
                        .fontWeight(.medium)
                }
            }
            .font(.caption)
        }
        .padding(16)
        .frame(width: 280)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var estimatedExhaustion: String {
        let days: Int
        if usageData.total > 0 {
            days = max(1, Int(Double(usageData.remains) / Double(usageData.total) * 30))
        } else {
            days = 1
        }
        return language.estimatedDaysText(days)
    }
}
