import SwiftUI

/// Settings 内部统一反馈视图。从旧 SettingsView 抽出来集中放。
struct InlineFeedback: Equatable {
    enum Kind: Equatable {
        case success
        case warning
        case error
    }

    let kind: Kind
    let message: String
}

@MainActor
struct InlineFeedbackView: View {
    let feedback: InlineFeedback

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbolName)
                .font(.system(size: 11, weight: .semibold))
            Text(feedback.message)
                .font(.system(size: 11))
                .lineLimit(2)
        }
        .foregroundStyle(color)
    }

    private var symbolName: String {
        switch feedback.kind {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch feedback.kind {
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
