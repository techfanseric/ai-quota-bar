import AppKit
import SwiftUI

/// Providers tab：左侧 provider 列表，右侧详情。
@MainActor
struct ProvidersPane: View {
    @Bindable var viewModel: UsageViewModel

    @State private var savedCredentials: [UsageProvider: String] = [:]
    @State private var selectedProvider: UsageProvider? = nil
    @State private var miniMaxCredential: String = ""
    @State private var miniMaxInputID: UUID = UUID()
    @State private var glmCredential: String = ""
    @State private var glmInputID: UUID = UUID()
    @State private var glmTestResult: InlineFeedback? = nil
    @State private var isTestingGLM: Bool = false
    @State private var kimiCredential: String = ""
    @State private var kimiInputID: UUID = UUID()
    @State private var codexSourceMode: CodexDataSourceMode = .default
    @State private var codexAccounts: [CodexAccountDraft] = []
    @State private var miniMaxTestResult: InlineFeedback? = nil
    @State private var isTestingMiniMax: Bool = false
    @State private var kimiTestResult: InlineFeedback? = nil
    @State private var isTestingKimi: Bool = false

    private var language: AppLanguage { viewModel.appLanguage }

    private var availableProviders: [UsageProvider] {
        UsageProvider.allCases
    }

    private var currentProvider: UsageProvider {
        if let selectedProvider { return selectedProvider }
        return availableProviders.first ?? .codex
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar
                .frame(width: 200)

            Divider()

            ProviderDetailView(
                provider: currentProvider,
                viewModel: viewModel,
                savedCredentials: savedCredentials,
                miniMaxCredential: $miniMaxCredential,
                kimiCredential: $kimiCredential,
                glmCredential: $glmCredential,
                codexSourceMode: $codexSourceMode,
                codexAccounts: codexAccounts,
                miniMaxTestResult: miniMaxTestResult,
                kimiTestResult: kimiTestResult,
                glmTestResult: glmTestResult,
                isTestingMiniMax: isTestingMiniMax,
                isTestingKimi: isTestingKimi,
                isTestingGLM: isTestingGLM,
                miniMaxInputID: miniMaxInputID,
                kimiInputID: kimiInputID,
                glmInputID: glmInputID,
                onTestConnection: testConnection,
                onSaveCredential: saveCredential,
                onAddCodexAccount: addCodexAccount,
                onRemoveCodexAccount: removeCodexAccount,
                onRefreshCodexAccount: refreshCodexAccount,
                onSignOutCodexAccount: signOutCodexAccount,
                onUpdateCodexSourceMode: updateCodexSourceMode
            )
        }
        .onAppear {
            loadFromViewModel()
        }
        .onChange(of: miniMaxCredential) { _, _ in miniMaxTestResult = nil }
        .onChange(of: kimiCredential) { _, _ in kimiTestResult = nil }
        .onChange(of: glmCredential) { _, _ in glmTestResult = nil }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(language.text(.providersTitle))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

            ForEach(availableProviders, id: \.self) { provider in
                sidebarRow(for: provider)
            }

            Spacer()
            if !viewModel.hasAnyCredential {
                Text(language == .simplifiedChinese ? "先连接一个供应商即可。Codex 可沿用本机登录，其他服务按需添加。" : "Start with one provider. Codex uses your local sign-in; add other services only when needed.")
                    .font(.caption).foregroundStyle(.secondary).padding(16)
            }
            DisclosureGroup(language == .simplifiedChinese ? "连接帮助" : "Connection help") {
                Text(language == .simplifiedChinese ? "若曾拒绝系统凭据授权，可在这里重试。" : "If you declined credential access, retry here.")
                    .foregroundStyle(.secondary).padding(.vertical, 6)
                Button(language == .simplifiedChinese ? "重试钥匙串访问" : "Retry Keychain access") {
                    KeychainService.shared.retryFailedAccess()
                    KeychainService.shared.preloadCredentialVault()
                    loadFromViewModel()
                }.buttonStyle(.plain)
            }.font(.caption).padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func sidebarRow(for provider: UsageProvider) -> some View {
        let isSelected = currentProvider == provider
        return Button {
            selectedProvider = provider
        } label: {
            HStack(spacing: 8) {
                ProviderLogoIcon(provider: provider, pointSize: 14)
                    .frame(width: 16)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(provider.displayName)
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
                Spacer()
                if !viewModel.isProviderEnabled(provider) {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help(language.providerPausedStatus())
                } else if viewModel.registeredProviders.contains(provider) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.12)
                    : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func loadFromViewModel() {
        let credentials = KeychainService.shared.providerCredentials()
        miniMaxCredential = credentials[.miniMax] ?? ""
        miniMaxInputID = UUID()
        kimiCredential = credentials[.kimi] ?? ""
        kimiInputID = UUID()
        let storedGLM = credentials[.glm] ?? ""
        glmCredential = (try? GLMCredential.parse(storedGLM).editableString) ?? storedGLM
        savedCredentials = [.miniMax: miniMaxCredential, .kimi: kimiCredential, .glm: glmCredential]
        glmInputID = UUID()
        codexSourceMode = CodexService.shared.sourceMode
        codexAccounts = CodexAccountCoordinator.shared.listAccountDrafts()
    }

    private func testConnection(for provider: UsageProvider) {
        Task { await runTestConnection(for: provider) }
    }

    private func runTestConnection(for provider: UsageProvider) async {
        setTesting(true, for: provider)
        setFeedback(nil, for: provider)

        let credential = credentialValue(for: provider)
        do {
            let success = try await viewModel.testCredential(
                credential.trimmingCharacters(in: .whitespacesAndNewlines),
                provider: provider
            )
            setFeedback(
                success
                    ? InlineFeedback(kind: .success, message: language.text(.testConnectionSuccess))
                    : InlineFeedback(kind: .error, message: language.text(.testConnectionRejected)),
                for: provider
            )
        } catch let error as UsageError {
            setFeedback(InlineFeedback(kind: .error, message: language.errorDescription(for: error)), for: provider)
        } catch {
            setFeedback(InlineFeedback(kind: .error, message: error.localizedDescription), for: provider)
        }

        setTesting(false, for: provider)
    }

    private func saveCredential(_ credential: String, for provider: UsageProvider) -> Bool {
        let trimmedCredential = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCredential.isEmpty {
            let success = KeychainService.shared.deleteCredential(for: provider)
            if success {
                savedCredentials[provider] = credential
                setFeedback(InlineFeedback(kind: .success, message: language.text(.settingsSaved)), for: provider)
                Task { await viewModel.refresh() }
            } else {
                setFeedback(InlineFeedback(kind: .error, message: language.text(.apiKeySaveFailed)), for: provider)
            }
            return success
        }
        let preparedCredential: String
        do {
            preparedCredential = try UsageService.shared.prepareCredentialForStorage(trimmedCredential, provider: provider)
        } catch let error as UsageError {
            setFeedback(InlineFeedback(kind: .error, message: language.errorDescription(for: error)), for: provider)
            return false
        } catch {
            setFeedback(InlineFeedback(kind: .error, message: error.localizedDescription), for: provider)
            return false
        }
        let success = KeychainService.shared.saveCredential(preparedCredential, for: provider)
        if success {
            savedCredentials[provider] = credential
            setFeedback(InlineFeedback(kind: .success, message: language.text(.settingsSaved)), for: provider)
            Task { await viewModel.refresh() }
        } else {
            setFeedback(InlineFeedback(kind: .error, message: language.text(.apiKeySaveFailed)), for: provider)
        }
        return success
    }

    private func credentialValue(for provider: UsageProvider) -> String {
        switch provider {
        case .miniMax: return miniMaxCredential
        case .codex: return ""
        case .glm: return glmCredential
        case .kimi: return kimiCredential
        }
    }

    private func setFeedback(_ feedback: InlineFeedback?, for provider: UsageProvider) {
        switch provider {
        case .miniMax: miniMaxTestResult = feedback
        case .codex: break
        case .glm: glmTestResult = feedback
        case .kimi: kimiTestResult = feedback
        }
    }

    private func setTesting(_ isTesting: Bool, for provider: UsageProvider) {
        switch provider {
        case .miniMax: isTestingMiniMax = isTesting
        case .codex: break
        case .glm: isTestingGLM = isTesting
        case .kimi: isTestingKimi = isTesting
        }
    }

    // MARK: - Codex actions

    private func addCodexAccount() {
        codexAccounts = CodexAccountCoordinator.shared.listAccountDrafts()
    }

    private func removeCodexAccount(_ id: String) {
        CodexAccountCoordinator.shared.removeAccount(id: id)
        codexAccounts = CodexAccountCoordinator.shared.listAccountDrafts()
    }

    private func refreshCodexAccount(id: String) {
        Task { await viewModel.refresh() }
    }

    private func signOutCodexAccount(id: String) {
        CodexAccountCoordinator.shared.removeAccount(id: id)
        codexAccounts = CodexAccountCoordinator.shared.listAccountDrafts()
    }

    private func updateCodexSourceMode(_ newMode: CodexDataSourceMode) {
        CodexService.shared.sourceMode = newMode
    }
}
