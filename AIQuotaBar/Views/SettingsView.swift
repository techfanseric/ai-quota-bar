import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject var viewModel: UsageViewModel
    @State private var miniMaxCredential: String = ""
    @State private var glmCredential: String = ""
    @State private var miniMaxCredentialInputID = UUID()
    @State private var glmCredentialInputID = UUID()
    @State private var refreshInterval: Int = 60
    @State private var warningThreshold: Double = 20
    @State private var autoRefreshOnLaunch: Bool = false
    @State private var appLanguage: AppLanguage = .english
    @State private var selectedModelName: String = ""
    @State private var miniMaxTestResult: InlineFeedback?
    @State private var glmTestResult: InlineFeedback?
    @State private var saveResult: InlineFeedback?
    @State private var isTestingMiniMax: Bool = false
    @State private var isTestingGLM: Bool = false
    @State private var isSaving: Bool = false
    @State private var updateResult: InlineFeedback?
    @State private var latestReleaseURL: URL?
    @State private var isCheckingUpdate: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                connectionSection

                behaviorSection

                appearanceSection

                updatesSection

                footer
            }
            .padding(24)
        }
        .frame(width: 700, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            loadCurrentSettings()
        }
    }

    private var language: AppLanguage {
        appLanguage
    }

    private var availableModelOptions: [ModelUsageData] {
        viewModel.availableModels
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 52, height: 52)

                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(language.text(.preferences))
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                Text(language.text(.preferencesSubtitle))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
    }

    private var connectionSection: some View {
        SettingsSectionCard(
            eyebrow: language.text(.connectionEyebrow),
            title: language.text(.connectionTitle),
            description: language.allProvidersConnectionDescription()
        ) {
            VStack(alignment: .leading, spacing: 18) {
                ProviderCredentialSection(
                    provider: .miniMax,
                    credential: $miniMaxCredential,
                    inputID: miniMaxCredentialInputID,
                    language: language,
                    isTesting: isTestingMiniMax,
                    feedback: miniMaxTestResult,
                    onTest: {
                        Task { await testConnection(for: .miniMax) }
                    }
                )

                Divider()

                ProviderCredentialSection(
                    provider: .glm,
                    credential: $glmCredential,
                    inputID: glmCredentialInputID,
                    language: language,
                    isTesting: isTestingGLM,
                    feedback: glmTestResult,
                    onTest: {
                        Task { await testConnection(for: .glm) }
                    }
                )
            }
        }
    }

    private var behaviorSection: some View {
        SettingsSectionCard(
            eyebrow: language.text(.behaviorEyebrow),
            title: language.text(.behaviorTitle),
            description: language.text(.behaviorDescription)
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(language.text(.refreshInterval))
                            .font(.system(size: 14, weight: .semibold))
                        Text(language.text(.refreshIntervalDescription))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Stepper(value: $refreshInterval, in: 15...3600, step: 15) {
                        ValueBadge(text: language.secondsText(refreshInterval))
                    }
                    .fixedSize()
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(language.text(.lowQuotaWarning))
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        ValueBadge(text: "\(Int(warningThreshold))%")
                    }

                    Slider(value: $warningThreshold, in: 1...100, step: 1)

                    Text(language.text(.lowQuotaWarningDescription))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Toggle(isOn: $autoRefreshOnLaunch) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(language.text(.refreshOnLaunch))
                            .font(.system(size: 14, weight: .semibold))
                        Text(language.text(.refreshOnLaunchDescription))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var appearanceSection: some View {
        SettingsSectionCard(
            eyebrow: language.text(.appearanceEyebrow),
            title: language.text(.appearanceTitle),
            description: language.text(.appearanceDescription)
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if !availableModelOptions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(language.text(.modelSelectionLabel))
                            .font(.system(size: 14, weight: .semibold))

                        Picker(language.text(.modelSelectionPlaceholder), selection: $selectedModelName) {
                            Text(language.text(.modelSelectionPlaceholder)).tag("")
                            ForEach(availableModelOptions) { model in
                                Text("\(model.provider.displayName) · \(model.modelName)").tag(model.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                Divider()
                    .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 10) {
                    Text(language.text(.languageTitle))
                        .font(.system(size: 14, weight: .semibold))

                    Text(language.text(.languageDescription))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Picker(language.text(.languageTitle), selection: $appLanguage) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let saveResult {
                InlineFeedbackView(feedback: saveResult)
            } else {
                Text(language.text(.changesApply))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(language.text(.saveChanges)) {
                saveSettings()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(isSaving)
        }
    }

    private var updatesSection: some View {
        SettingsSectionCard(
            eyebrow: language.text(.updatesEyebrow),
            title: language.text(.updatesTitle),
            description: language.text(.updatesDescription)
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(language.text(.currentVersion))
                        .font(.system(size: 14, weight: .semibold))

                    Spacer()

                    ValueBadge(text: UpdateChecker.currentAppVersion)
                }

                HStack(spacing: 10) {
                    Button {
                        Task {
                            await checkForUpdates()
                        }
                    } label: {
                        Label(language.text(.checkForUpdates), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isCheckingUpdate)

                    if isCheckingUpdate {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if let latestReleaseURL {
                        Button {
                            openURL(latestReleaseURL)
                        } label: {
                            Label(language.text(.openReleasePage), systemImage: "safari")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Spacer()
                }

                if let updateResult {
                    InlineFeedbackView(feedback: updateResult)
                }
            }
        }
    }

    private func loadCurrentSettings() {
        miniMaxCredential = KeychainService.shared.getCredential(for: .miniMax) ?? ""
        glmCredential = KeychainService.shared.getCredential(for: .glm) ?? ""
        miniMaxCredentialInputID = UUID()
        glmCredentialInputID = UUID()
        refreshInterval = viewModel.refreshInterval
        warningThreshold = viewModel.warningThreshold
        autoRefreshOnLaunch = viewModel.autoRefreshOnLaunch
        appLanguage = viewModel.appLanguage
        selectedModelName = viewModel.selectedModelName ?? ""
    }

    private func testConnection(for provider: UsageProvider) async {
        setTesting(true, for: provider)
        setFeedback(nil, for: provider)

        let credential = credentialValue(for: provider)

        do {
            let success = try await viewModel.testCredential(
                credential.trimmingCharacters(in: .whitespacesAndNewlines),
                provider: provider
            )
            setFeedback(success
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

    private func saveSettings() {
        isSaving = true
        saveResult = nil

        viewModel.refreshInterval = refreshInterval
        viewModel.warningThreshold = warningThreshold
        viewModel.autoRefreshOnLaunch = autoRefreshOnLaunch
        viewModel.appLanguage = appLanguage
        viewModel.selectedModelName = selectedModelName.isEmpty ? nil : selectedModelName

        let miniMaxSaved = saveCredential(miniMaxCredential, for: .miniMax)
        let glmSaved = saveCredential(glmCredential, for: .glm)
        let credentialsSaved = miniMaxSaved && glmSaved

        if credentialsSaved {
            miniMaxCredential = KeychainService.shared.getCredential(for: .miniMax) ?? ""
            glmCredential = KeychainService.shared.getCredential(for: .glm) ?? ""
            miniMaxCredentialInputID = UUID()
            glmCredentialInputID = UUID()
            Task { await viewModel.refresh() }
        }

        saveResult = credentialsSaved
            ? InlineFeedback(kind: .success, message: language.text(.settingsSaved))
            : InlineFeedback(kind: .error, message: language.text(.apiKeySaveFailed))

        isSaving = false
    }

    private func saveCredential(_ credential: String, for provider: UsageProvider) -> Bool {
        let trimmedCredential = credential.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedCredential.isEmpty {
            return KeychainService.shared.deleteCredential(for: provider)
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

        return KeychainService.shared.saveCredential(preparedCredential, for: provider)
    }

    private func credentialValue(for provider: UsageProvider) -> String {
        switch provider {
        case .miniMax:
            return miniMaxCredential
        case .glm:
            return glmCredential
        }
    }

    private func setFeedback(_ feedback: InlineFeedback?, for provider: UsageProvider) {
        switch provider {
        case .miniMax:
            miniMaxTestResult = feedback
        case .glm:
            glmTestResult = feedback
        }
    }

    private func setTesting(_ isTesting: Bool, for provider: UsageProvider) {
        switch provider {
        case .miniMax:
            isTestingMiniMax = isTesting
        case .glm:
            isTestingGLM = isTesting
        }
    }

    private func checkForUpdates() async {
        isCheckingUpdate = true
        updateResult = nil
        latestReleaseURL = nil

        do {
            let outcome = try await UpdateChecker.shared.checkForUpdates()
            switch outcome {
            case .upToDate(let currentVersion):
                updateResult = InlineFeedback(
                    kind: .success,
                    message: language.upToDateText(current: currentVersion)
                )
            case .updateAvailable(let currentVersion, let latestVersion, let releaseURL):
                latestReleaseURL = releaseURL
                updateResult = InlineFeedback(
                    kind: .success,
                    message: language.updateAvailableText(current: currentVersion, latest: latestVersion)
                )
            }
        } catch {
            let message = error.localizedDescription.isEmpty ? language.text(.unknownError) : error.localizedDescription
            updateResult = InlineFeedback(
                kind: .error,
                message: language.updateCheckFailedText(message)
            )
        }

        isCheckingUpdate = false
    }
}

private struct ProviderCredentialSection: View {
    let provider: UsageProvider
    @Binding var credential: String
    let inputID: UUID
    let language: AppLanguage
    let isTesting: Bool
    let feedback: InlineFeedback?
    let onTest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(provider.displayName)
                    .font(.system(size: 14, weight: .semibold))

                Spacer()
            }

            CredentialInputField(
                provider: provider,
                credential: $credential,
                language: language
            )
            .id(inputID)

            Text(language.credentialHelpText(for: provider))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    onTest()
                } label: {
                    Label(language.text(.testConnection), systemImage: "bolt.horizontal.circle")
                }
                .buttonStyle(.bordered)
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

private struct CredentialInputField: View {
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
        return "\(prefix)...\(suffix)"
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

private struct SettingsSectionCard<Content: View>: View {
    let eyebrow: String
    let title: String
    let description: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Text(title)
                    .font(.system(size: 18, weight: .semibold))

                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct ValueBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
    }
}

private struct InlineFeedback {
    enum Kind {
        case success
        case error
    }

    let kind: Kind
    let message: String

    var tint: Color {
        switch kind {
        case .success:
            return .green
        case .error:
            return .red
        }
    }

    var iconName: String {
        switch kind {
        case .success:
            return "checkmark.circle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }
}

private struct InlineFeedbackView: View {
    let feedback: InlineFeedback

    var body: some View {
        Label(feedback.message, systemImage: feedback.iconName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(feedback.tint)
    }
}
