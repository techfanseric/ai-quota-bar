import SwiftUI

struct SettingsView: View {
    enum SettingsTab: Hashable {
        case connection
        case behavior
        case appearance
    }

    @ObservedObject var viewModel: UsageViewModel
    var onPreferredHeightChange: ((CGFloat) -> Void)?

    @State private var apiKey: String = ""
    @State private var refreshInterval: Int = 60
    @State private var warningThreshold: Double = 20
    @State private var autoRefreshOnLaunch: Bool = false
    @State private var displayFormat: DisplayFormat = .leveled
    @State private var appLanguage: AppLanguage = .english
    @State private var selectedTab: SettingsTab = .connection
    @State private var testResult: InlineFeedback?
    @State private var saveResult: InlineFeedback?
    @State private var isTesting: Bool = false
    @State private var isSaving: Bool = false

    @State private var headerHeight: CGFloat = 0
    @State private var tabBarHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
                .measureHeight { headerHeight = $0 }

            tabStrip
                .measureHeight { tabBarHeight = $0 }

            activeTabContent
                .measureHeight { contentHeight = $0 }

            footer
                .measureHeight { footerHeight = $0 }
        }
        .padding(24)
        .frame(width: 700, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            loadCurrentSettings()
            reportPreferredHeight()
        }
        .onChange(of: selectedTab) { reportPreferredHeight() }
        .onChange(of: headerHeight) { reportPreferredHeight() }
        .onChange(of: tabBarHeight) { reportPreferredHeight() }
        .onChange(of: contentHeight) { reportPreferredHeight() }
        .onChange(of: footerHeight) { reportPreferredHeight() }
    }

    private var language: AppLanguage {
        appLanguage
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

    private var tabStrip: some View {
        HStack(spacing: 10) {
            SettingsTabButton(
                title: language.text(.tabConnection),
                systemImage: "key.fill",
                isSelected: selectedTab == .connection
            ) {
                selectedTab = .connection
            }

            SettingsTabButton(
                title: language.text(.tabBehavior),
                systemImage: "clock.arrow.circlepath",
                isSelected: selectedTab == .behavior
            ) {
                selectedTab = .behavior
            }

            SettingsTabButton(
                title: language.text(.tabAppearance),
                systemImage: "paintbrush.pointed.fill",
                isSelected: selectedTab == .appearance
            ) {
                selectedTab = .appearance
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var activeTabContent: some View {
        switch selectedTab {
        case .connection:
            connectionTab
        case .behavior:
            behaviorTab
        case .appearance:
            appearanceTab
        }
    }

    private var connectionTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            connectionSection
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var behaviorTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            refreshSection
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var appearanceTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            displaySection
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var connectionSection: some View {
        SettingsSectionCard(
            eyebrow: language.text(.connectionEyebrow),
            title: language.text(.connectionTitle),
            description: language.text(.connectionDescription)
        ) {
            VStack(alignment: .leading, spacing: 14) {
                SecureField(language.text(.apiKeyPlaceholder), text: $apiKey)
                    .textFieldStyle(.roundedBorder)

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

    private var refreshSection: some View {
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

    private var displaySection: some View {
        SettingsSectionCard(
            eyebrow: language.text(.appearanceEyebrow),
            title: language.text(.appearanceTitle),
            description: language.text(.appearanceDescription)
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(DisplayFormat.allCases, id: \.self) { format in
                    Button {
                        displayFormat = format
                    } label: {
                        HStack(alignment: .top, spacing: 14) {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 8) {
                                    Text(format.title(language: language))
                                        .font(.system(size: 14, weight: .semibold))

                                    Text(format.preview(language: language))
                                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(Color.primary.opacity(0.06))
                                        )
                                }

                                Text(format.caption(language: language))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: displayFormat == format ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(displayFormat == format ? Color.accentColor : .secondary.opacity(0.6))
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(displayFormat == format ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(displayFormat == format ? Color.accentColor.opacity(0.32) : Color.primary.opacity(0.08), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
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
        displayFormat = viewModel.displayFormat
        appLanguage = viewModel.appLanguage
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
        viewModel.displayFormat = displayFormat
        viewModel.appLanguage = appLanguage

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

    private func reportPreferredHeight() {
        let preferredHeight = headerHeight + tabBarHeight + contentHeight + footerHeight + 128
        guard preferredHeight > 0 else { return }
        DispatchQueue.main.async {
            onPreferredHeightChange?(preferredHeight)
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

private struct SettingsTabButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(isSelected ? Color.accentColor.opacity(0.30) : Color.primary.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
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

private struct HeightReader: ViewModifier {
    let onChange: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        onChange(proxy.size.height)
                    }
                    .onChange(of: proxy.size.height) {
                        onChange(proxy.size.height)
                    }
            }
        )
    }
}

private extension View {
    func measureHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        modifier(HeightReader(onChange: onChange))
    }
}
