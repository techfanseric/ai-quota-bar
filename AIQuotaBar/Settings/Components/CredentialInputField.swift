import AppKit
import SwiftUI

/// A stable native field for both API keys and imported request credentials.
@MainActor
struct CredentialInputField: View {
    let provider: UsageProvider
    @Binding var credential: String
    let language: AppLanguage

    @State private var isRevealed = false
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case secure, revealed }
    private var isChinese: Bool { language == .simplifiedChinese }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(provider == .kimi
                 ? (isChinese ? "API Key（可选）" : "API key (optional)")
                 : (isChinese ? "API Key" : "API key"))
                .font(.body.weight(.medium))

            HStack(spacing: 8) {
                Group {
                    if isRevealed {
                        TextField(language.credentialPlaceholder(for: provider), text: $credential)
                            .focused($focusedField, equals: .revealed)
                    } else {
                        SecureField(language.credentialPlaceholder(for: provider), text: $credential)
                            .focused($focusedField, equals: .secure)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .autocorrectionDisabled()
                .accessibilityLabel(provider.displayName + " API Key")
                .frame(maxWidth: .infinity)

                Button {
                    isRevealed.toggle()
                    focusedField = isRevealed ? .revealed : .secure
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .frame(width: 20, height: 20)
                }
                .help(isRevealed
                      ? (isChinese ? "隐藏凭据" : "Hide credential")
                      : (isChinese ? "显示凭据" : "Show credential"))
                .accessibilityLabel(isRevealed
                                    ? (isChinese ? "隐藏凭据" : "Hide credential")
                                    : (isChinese ? "显示凭据" : "Show credential"))
                .disabled(credential.isEmpty)

                Button(isChinese ? "粘贴" : "Paste") {
                    guard let value = NSPasteboard.general.string(forType: .string) else { return }
                    credential = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    isRevealed = false
                    focusedField = .secure
                }
                .help(language.pasteFromClipboardText())
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .onDisappear { isRevealed = false }
    }
}
