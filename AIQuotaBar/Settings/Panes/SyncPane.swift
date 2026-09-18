import SwiftUI

@MainActor
struct CloudSyncStatusLine: View {
    let status: CloudSyncStatus
    let language: AppLanguage

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)

            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var dotColor: Color {
        switch status {
        case .idle: return .secondary
        case .success: return .green
        case .failure: return .red
        }
    }

    private var text: String {
        switch status {
        case .idle:
            return language.text(.cloudSyncStatusIdle)
        case .success(let date):
            return language.cloudSyncStatusSuccess(relative: Self.relativeFormatter.localizedString(for: date, relativeTo: Date()))
        case .failure(let date, _, let error):
            return language.cloudSyncStatusFailure(
                relative: Self.relativeFormatter.localizedString(for: date, relativeTo: Date()),
                detail: error?.localizedDescription ?? ""
            )
        }
    }
}
