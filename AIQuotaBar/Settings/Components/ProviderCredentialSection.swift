import SwiftUI

@MainActor
struct ProviderCredentialSection: View {
    let provider: UsageProvider
    @Binding var credential: String
    let savedCredential: String
    let inputID: UUID
    let language: AppLanguage
    let isTesting: Bool
    let feedback: InlineFeedback?
    var allowsEmptyCredentialTest: Bool = false
    let onTest: () -> Void
    let onSave: () -> Bool

    @State private var fieldRevision = UUID()

    private var hasChanges: Bool {
        return credential != savedCredential
    }
    private var isChinese: Bool { language == .simplifiedChinese }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CredentialInputField(
                provider: provider,
                credential: $credential,
                language: language
            )
            .id(fieldRevision)
            .disabled(isTesting)

            Text(language.credentialHelpText(for: provider))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(language.text(.saveChanges)) {
                    if onSave() {
                        fieldRevision = UUID()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isTesting || !hasChanges)

                Button(language.text(.testConnection), action: onTest)
                    .buttonStyle(.bordered)
                    .disabled(isTesting || (!allowsEmptyCredentialTest
                        && credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))

                if hasChanges {
                    Button(isChinese ? "撤销修改" : "Revert Changes") {
                        credential = savedCredential
                        fieldRevision = UUID()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isTesting)
                }

                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(isChinese ? "正在测试连接" : "Testing connection")
                }
            }
            .controlSize(.regular)

            if let feedback {
                InlineFeedbackView(feedback: feedback)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: inputID) { _, _ in
            fieldRevision = UUID()
        }
    }
}
