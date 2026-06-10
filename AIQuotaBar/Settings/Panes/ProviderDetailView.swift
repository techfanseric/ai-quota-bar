import AppKit
import SwiftUI

/// 单个 provider 的详情视图。ProvidersPane 右侧内容区。
@MainActor
struct ProviderDetailView: View {
    let provider: UsageProvider
    @Bindable var viewModel: UsageViewModel
    @Binding var miniMaxCredential: String
    @Binding var codexSourceMode: CodexDataSourceMode
    let codexAccounts: [CodexAccountDraft]
    let miniMaxTestResult: InlineFeedback?
    let isTestingMiniMax: Bool
    let miniMaxInputID: UUID
    let onTestConnection: (UsageProvider) -> Void
    let onSaveCredential: (String, UsageProvider) -> Bool
    let onAddCodexAccount: () -> Void
    let onRemoveCodexAccount: (String) -> Void
    let onRefreshCodexAccount: (String) -> Void
    let onSignOutCodexAccount: (String) -> Void
    let onUpdateCodexSourceMode: (CodexDataSourceMode) -> Void

    private var language: AppLanguage { viewModel.appLanguage }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection(title: provider.displayName) {
                    providerContent
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var providerContent: some View {
        switch provider {
        case .miniMax:
            ProviderCredentialSection(
                provider: .miniMax,
                credential: $miniMaxCredential,
                inputID: miniMaxInputID,
                language: language,
                isTesting: isTestingMiniMax,
                feedback: miniMaxTestResult,
                onTest: { onTestConnection(.miniMax) },
                onSave: { _ = onSaveCredential(miniMaxCredential, .miniMax) }
            )
        case .codex:
            CodexSettingsSection(
                language: language,
                sourceMode: $codexSourceMode,
                accounts: codexAccounts,
                onAdd: onAddCodexAccount,
                onRemove: onRemoveCodexAccount,
                onRefresh: onRefreshCodexAccount,
                onSignOut: onSignOutCodexAccount,
                onSourceModeChange: onUpdateCodexSourceMode
            )
        case .glm:
            EmptyView()
        }
    }
}
