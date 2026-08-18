import AppKit
import SwiftUI

/// Providers tab：左侧 provider 列表，右侧详情。
@MainActor
struct ProvidersPane: View {
    @Bindable var viewModel: UsageViewModel

    @State private var selectedProvider: UsageProvider? = nil
    @State private var miniMaxCredential: String = ""
    @State private var miniMaxInputID: UUID = UUID()
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
                miniMaxCredential: $miniMaxCredential,
                kimiCredential: $kimiCredential,
                codexSourceMode: $codexSourceMode,
                codexAccounts: codexAccounts,
                miniMaxTestResult: miniMaxTestResult,
                kimiTestResult: kimiTestResult,
                isTestingMiniMax: isTestingMiniMax,
                isTestingKimi: isTestingKimi,
                miniMaxInputID: miniMaxInputID,
                kimiInputID: kimiInputID,
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
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func sidebarRow(for provider: UsageProvider) -> some View {
        let isSelected = currentProvider == provider
        return Button {
            selectedProvider = provider
        } label: {
            HStack(spacing: 8) {
                Image(systemName: iconName(for: provider))
                    .frame(width: 16)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(provider.displayName)
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
                Spacer()
                if viewModel.configuredProviders.contains(provider) {
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

    private func iconName(for provider: UsageProvider) -> String {
        switch provider {
        case .miniMax: return "circle.hexagongrid"
        case .codex: return "terminal"
        case .glm: return "rectangle.grid.2x2"
        case .kimi: return "moon.stars"
        }
    }

    // MARK: - Actions

    private func loadFromViewModel() {
        miniMaxCredential = KeychainService.shared.getCredential(for: .miniMax) ?? ""
        miniMaxInputID = UUID()
        kimiCredential = KeychainService.shared.getCredential(for: .kimi) ?? ""
        kimiInputID = UUID()
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
        case .glm: return ""
        case .kimi: return kimiCredential
        }
    }

    private func setFeedback(_ feedback: InlineFeedback?, for provider: UsageProvider) {
        switch provider {
        case .miniMax: miniMaxTestResult = feedback
        case .codex: break
        case .glm: break
        case .kimi: kimiTestResult = feedback
        }
    }

    private func setTesting(_ isTesting: Bool, for provider: UsageProvider) {
        switch provider {
        case .miniMax: isTestingMiniMax = isTesting
        case .codex: break
        case .glm: break
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
