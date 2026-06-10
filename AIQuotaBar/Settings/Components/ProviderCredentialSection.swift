import SwiftUI

/// 单个 provider 的凭据 section。codexbar 风格：input + 描述 + 测试/反馈。
@MainActor
struct ProviderCredentialSection: View {
    let provider: UsageProvider
    @Binding var credential: String
    let inputID: UUID
    let language: AppLanguage
    let isTesting: Bool
    let feedback: InlineFeedback?
    let onTest: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CredentialInputField(
                provider: provider,
                credential: $credential,
                language: language
            )
            .id(inputID)

            Text(language.credentialHelpText(for: provider))
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    onSave()
                } label: {
                    Label(language.text(.saveChanges), systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isTesting)

                Button {
                    onTest()
                } label: {
                    Label(language.text(.testConnection), systemImage: "bolt.horizontal.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting)

                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                if let feedback {
                    InlineFeedbackView(feedback: feedback)
                }
            }
        }
    }
}
