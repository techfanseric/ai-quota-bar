import SwiftUI

/// codexbar 风格的 Codex 配置 section：title + source mode picker + 账号列表。
@MainActor
struct CodexSettingsSection: View {
    let language: AppLanguage
    @Binding var sourceMode: CodexDataSourceMode
    let accounts: [CodexAccountDraft]
    let onAdd: () -> Void
    let onRemove: (String) -> Void
    let onRefresh: (String) -> Void
    let onSignOut: (String) -> Void
    let onSourceModeChange: (CodexDataSourceMode) -> Void
    @State private var showingAddAlert: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PreferencePickerRow(
                title: language.codexSourceModeLabel(),
                subtitle: nil,
                selection: $sourceMode,
                maxWidth: 200
            ) {
                ForEach(CodexDataSourceMode.allCases) { mode in
                    Text(language.codexSourceModeDisplayName(mode)).tag(mode)
                }
            }
            .onChange(of: sourceMode) { _, newMode in
                onSourceModeChange(newMode)
            }

            Text(language.codexAccountsHelpText())
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if accounts.isEmpty {
                Text(language.codexAccountEmptyStateText())
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(accounts) { account in
                        CodexAccountRow(
                            account: account,
                            language: language,
                            onRefresh: { onRefresh(account.id) },
                            onSignOut: { onSignOut(account.id) },
                            onRemove: { onRemove(account.id) })
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    showingAddAlert = true
                } label: {
                    Label(language.codexAccountAddButtonText(), systemImage: "plus.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .alert(language.codexAccountAddButtonText(), isPresented: $showingAddAlert) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(language.codexAccountEmptyStateText())
                }

                Spacer()
            }
        }
    }
}

private struct CodexAccountRow: View {
    let account: CodexAccountDraft
    let language: AppLanguage
    let onRefresh: () -> Void
    let onSignOut: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if account.isActive {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                }

                Text(displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Spacer()

                Text(account.sourceLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                if !account.planType.isEmpty {
                    Text("Plan \(account.planType.capitalized)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let last = account.lastRefresh {
                    Text(language.codexLastRefreshedText(last))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            HStack(spacing: 8) {
                Button {
                    onRefresh()
                } label: {
                    Label(language.codexAccountRefreshButtonText(), systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    onSignOut()
                } label: {
                    Label(language.codexAccountSignOutButtonText(), systemImage: "rectangle.portrait.and.arrow.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label(language.codexAccountRemoveButtonText(), systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var displayName: String {
        account.name.isEmpty ? account.email : account.name
    }
}
