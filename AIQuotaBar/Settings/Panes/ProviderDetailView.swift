import AppKit
import SwiftUI

/// 单个 provider 的详情视图。ProvidersPane 右侧内容区。
@MainActor
struct ProviderDetailView: View {
    let provider: UsageProvider
    @Bindable var viewModel: UsageViewModel
    let savedCredentials: [UsageProvider: String]
    @Binding var miniMaxCredential: String
    @Binding var kimiCredential: String
    @Binding var glmCredential: String
    @Binding var codexSourceMode: CodexDataSourceMode
    let codexAccounts: [CodexAccountDraft]
    let miniMaxTestResult: InlineFeedback?
    let kimiTestResult: InlineFeedback?
    let glmTestResult: InlineFeedback?
    let isTestingMiniMax: Bool
    let isTestingKimi: Bool
    let isTestingGLM: Bool
    let miniMaxInputID: UUID
    let kimiInputID: UUID
    let glmInputID: UUID
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
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(isOn: providerEnabledBinding) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(language.providerMonitoringTitle())
                                Text(language.providerMonitoringDescription())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)

                        Divider()

                        providerContent
                            .disabled(!viewModel.isProviderEnabled(provider))
                            .opacity(viewModel.isProviderEnabled(provider) ? 1 : 0.55)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private var providerEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isProviderEnabled(provider) },
            set: { isEnabled in
                viewModel.setProviderEnabled(isEnabled, provider: provider)
                if isEnabled {
                    Task { await viewModel.refresh() }
                }
            })
    }

    @ViewBuilder
    private var providerContent: some View {
        switch provider {
        case .miniMax:
            ProviderCredentialSection(
                provider: .miniMax,
                credential: $miniMaxCredential,
                savedCredential: savedCredentials[.miniMax] ?? "",
                inputID: miniMaxInputID,
                language: language,
                isTesting: isTestingMiniMax,
                feedback: miniMaxTestResult,
                onTest: { onTestConnection(.miniMax) },
                onSave: { onSaveCredential(miniMaxCredential, .miniMax) }
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
        case .kimi:
            ProviderCredentialSection(
                provider: .kimi,
                credential: $kimiCredential,
                savedCredential: savedCredentials[.kimi] ?? "",
                inputID: kimiInputID,
                language: language,
                isTesting: isTestingKimi,
                feedback: kimiTestResult,
                allowsEmptyCredentialTest: true,
                onTest: { onTestConnection(.kimi) },
                onSave: { onSaveCredential(kimiCredential, .kimi) }
            )
        case .glm:
            ProviderCredentialSection(
                provider: .glm,
                credential: $glmCredential,
                savedCredential: savedCredentials[.glm] ?? "",
                inputID: glmInputID,
                language: language,
                isTesting: isTestingGLM,
                feedback: glmTestResult,
                onTest: { onTestConnection(.glm) },
                onSave: { onSaveCredential(glmCredential, .glm) }
            )
            Link(language == .simplifiedChinese ? "打开GLM 用量页面" : "Open BigModel usage",
                 destination: URL(string: "https://bigmodel.cn/coding-plan/personal/usage")!)
        }
    }
}
