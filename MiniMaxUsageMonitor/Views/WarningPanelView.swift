import SwiftUI

struct WarningPanelView: View {
    let usageData: UsageData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.title2)
                Text("Low Quota Warning")
                    .font(.headline)
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Remaining:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(usageData.remains) (\(Int(usageData.percentageRemaining))%)")
                        .fontWeight(.bold)
                }

                HStack {
                    Text("Time:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(usageData.timestamp, style: .time)
                }

                HStack {
                    Text("Est. exhaustion:")
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
        let days = max(1, Int(Double(usageData.remains) / Double(usageData.total) * 30))
        return "~ \(days) day\(days == 1 ? "" : "s")"
    }
}