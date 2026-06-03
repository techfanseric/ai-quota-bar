import AppKit
import SwiftUI

/// Provider 凭据输入框。支持 mask 显示与编辑模式切换；CURL 类 provider 提供粘贴/全选辅助。
@MainActor
struct CredentialInputField: View {
    let provider: UsageProvider
    @Binding var credential: String
    let language: AppLanguage

    @State private var isEditing: Bool = false
    @State private var draftKey: String = ""
    @FocusState private var isTextEditorFocused: Bool

    private var maskedKey: String {
        let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return trimmed }
        let prefix = String(trimmed.prefix(6))
        let suffix = String(trimmed.suffix(4))
        return "\(prefix)…\(suffix)"
    }

    var body: some View {
        HStack(spacing: 8) {
            if credential.isEmpty || isEditing {
                if provider.usesCurlCredential {
                    VStack(alignment: .trailing, spacing: 8) {
                        TextEditor(text: $draftKey)
                            .font(.system(size: 11, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .focused($isTextEditorFocused)
                            .frame(maxWidth: .infinity, minHeight: 88, maxHeight: 88, alignment: .topLeading)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor))
                            )
                            .overlay(alignment: .topLeading) {
                                if draftKey.isEmpty {
                                    Text(language.credentialPlaceholder(for: provider))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 16)
                                        .allowsHitTesting(false)
                                }
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                            )
                            .onChange(of: draftKey) { _, newValue in
                                credential = newValue
                            }

                        HStack(spacing: 8) {
                            Button {
                                selectAllText()
                            } label: {
                                Label(language.selectAllText(), systemImage: "selection.pin.in.out")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button {
                                pasteFromClipboard()
                            } label: {
                                Label(language.pasteFromClipboardText(), systemImage: "doc.on.clipboard")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .onAppear {
                        if draftKey.isEmpty {
                            draftKey = credential
                        }
                        isEditing = true
                    }
                } else {
                    TextField(language.credentialPlaceholder(for: provider), text: $draftKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                        .onChange(of: draftKey) { _, newValue in
                            credential = newValue
                        }
                        .onAppear {
                            if draftKey.isEmpty {
                                draftKey = credential
                            }
                            isEditing = true
                        }
                }
            } else {
                Text(maskedKey)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                    )

                Button {
                    credential = ""
                    draftKey = ""
                    isEditing = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func pasteFromClipboard() {
        guard let string = NSPasteboard.general.string(forType: .string),
              !string.isEmpty else {
            return
        }

        draftKey = string
        credential = string
        isEditing = true
    }

    private func selectAllText() {
        if draftKey.isEmpty {
            draftKey = credential
        }

        isTextEditorFocused = true
        DispatchQueue.main.async {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }
}
