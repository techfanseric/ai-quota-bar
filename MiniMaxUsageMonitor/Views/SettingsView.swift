import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: UsageViewModel
    @State private var apiKey: String = ""
    @State private var refreshInterval: Int = 60
    @State private var warningThreshold: Double = 20
    @State private var autoRefreshOnLaunch: Bool = false
    @State private var appLanguage: AppLanguage = .english
    @State private var selectedModelName: String = ""
    @State private var testResult: InlineFeedback?
    @State private var saveResult: InlineFeedback?
    @State private var isTesting: Bool = false
    @State private var isSaving: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                connectionSection

                behaviorSection

                appearanceSection

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

    private var availableModelNames: [String] {
        viewModel.availableModels.map(\.modelName)
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
            description: language.text(.connectionDescription)
        ) {
            VStack(alignment: .leading, spacing: 14) {
                APIKeyInputField(apiKey: $apiKey)

                HStack(spacing: 10) {
                    Button {
                        Task {
                            await testConnection()
                        }
                    } label: {
                        Label(language.text(.testConnection), systemImage: "bolt.horizontal.circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting)

                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()

                    if let testResult {
                        InlineFeedbackView(feedback: testResult)
                    }
                }
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
                if !availableModelNames.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(language.text(.modelSelectionLabel))
                            .font(.system(size: 14, weight: .semibold))

                        Picker(language.text(.modelSelectionPlaceholder), selection: $selectedModelName) {
                            Text(language.text(.modelSelectionPlaceholder)).tag("")
                            ForEach(availableModelNames, id: \.self) { modelName in
                                Text(modelName).tag(modelName)
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

    private func loadCurrentSettings() {
        apiKey = KeychainService.shared.getAPIKey() ?? ""
        refreshInterval = viewModel.refreshInterval
        warningThreshold = viewModel.warningThreshold
        autoRefreshOnLaunch = viewModel.autoRefreshOnLaunch
        appLanguage = viewModel.appLanguage
        selectedModelName = viewModel.selectedModelName ?? ""
    }

    private func testConnection() async {
        isTesting = true
        testResult = nil

        do {
            let success = try await viewModel.testAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            testResult = success
                ? InlineFeedback(kind: .success, message: language.text(.testConnectionSuccess))
                : InlineFeedback(kind: .error, message: language.text(.testConnectionRejected))
        } catch let error as UsageError {
            testResult = InlineFeedback(kind: .error, message: language.errorDescription(for: error))
        } catch {
            testResult = InlineFeedback(kind: .error, message: error.localizedDescription)
        }

        isTesting = false
    }

    private func saveSettings() {
        isSaving = true
        saveResult = nil

        viewModel.refreshInterval = refreshInterval
        viewModel.warningThreshold = warningThreshold
        viewModel.autoRefreshOnLaunch = autoRefreshOnLaunch
        viewModel.appLanguage = appLanguage
        viewModel.selectedModelName = selectedModelName.isEmpty ? nil : selectedModelName

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKeySaved: Bool

        if trimmedKey.isEmpty {
            apiKeySaved = KeychainService.shared.deleteAPIKey()
            Task {
                await viewModel.refresh()
            }
        } else {
            apiKeySaved = viewModel.saveAPIKey(trimmedKey)
        }

        saveResult = apiKeySaved
            ? InlineFeedback(kind: .success, message: language.text(.settingsSaved))
            : InlineFeedback(kind: .error, message: language.text(.apiKeySaveFailed))

        isSaving = false
    }
}

private struct APIKeyInputField: View {
    @Binding var apiKey: String
    @State private var isEditing: Bool = false
    @State private var draftKey: String = ""

    private var maskedKey: String {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return trimmed }
        let prefix = String(trimmed.prefix(6))
        let suffix = String(trimmed.suffix(4))
        return "\(prefix)...\(suffix)"
    }

    var body: some View {
        HStack(spacing: 8) {
            if apiKey.isEmpty {
                TextField("MiniMax API Key", text: $draftKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: draftKey) { _, newValue in
                        if !isEditing {
                            apiKey = newValue
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
                    apiKey = ""
                    draftKey = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
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
