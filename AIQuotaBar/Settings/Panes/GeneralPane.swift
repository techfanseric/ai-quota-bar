import AppKit
import SwiftUI

/// General tab：语言、刷新行为、云同步、退出按钮。
@MainActor
struct GeneralPane: View {
    @Bindable var viewModel: UsageViewModel
    @State private var cloudSyncTestResult: InlineFeedback?
    @State private var isTestingCloudSync: Bool = false
    @State private var isOpeningCloudData: Bool = false
    @State private var isDeletingLocalData: Bool = false
    @State private var isDeletingRemoteData: Bool = false
    @State private var isConfirmingLocalDelete: Bool = false
    @State private var isConfirmingRemoteDelete: Bool = false

    private var language: AppLanguage { viewModel.appLanguage }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                systemSection
                Divider()
                usageSection
                Divider()
                cloudSyncSection
                Divider()
                quitSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    // MARK: - SYSTEM

    private var systemSection: some View {
        SettingsSection(title: language.text(.systemTitle), contentSpacing: 12) {
            PreferencePickerRow(
                title: language.text(.languageTitle),
                subtitle: language.text(.languageDescription),
                selection: $viewModel.appLanguage,
                maxWidth: 200
            ) {
                ForEach(AppLanguage.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
        }
    }

    // MARK: - USAGE

    private var usageSection: some View {
        SettingsSection(title: language.text(.usageTitle), contentSpacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Toggle(isOn: $viewModel.warningThresholdEnabled) {
                    HStack {
                        Text(language.text(.lowQuotaWarning))
                            .font(.body)
                        Spacer()
                        if viewModel.warningThresholdEnabled {
                            Text("\(Int(viewModel.warningThreshold))%")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.checkbox)

                if viewModel.warningThresholdEnabled {
                    Slider(value: $viewModel.warningThreshold, in: 1...100, step: 1)
                }

                Text(language.text(.lowQuotaWarningDescription))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PreferencePickerRow(
                title: language.text(.refreshInterval),
                subtitle: language.text(.refreshIntervalDescription),
                selection: $viewModel.refreshInterval,
                maxWidth: 140
            ) {
                ForEach(refreshIntervalOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }

            PreferenceToggleRow(
                title: language.text(.refreshOnLaunch),
                subtitle: language.text(.refreshOnLaunchDescription),
                isOn: $viewModel.autoRefreshOnLaunch
            )

            PreferenceToggleRow(
                title: language.text(.launchAtLogin),
                subtitle: language.text(.launchAtLoginDescription),
                isOn: $viewModel.launchAtLogin
            )

            PreferencePickerRow(
                title: language.utilizationHistoryModeLabel(),
                subtitle: language.utilizationHistoryModeDescription(),
                selection: $viewModel.utilizationHistoryMode,
                maxWidth: 220
            ) {
                ForEach(UtilizationHistoryMode.allCases) { mode in
                    Text(language.utilizationHistoryModeDisplayName(mode)).tag(mode)
                }
            }
        }
    }

    private var refreshIntervalOptions: [(label: String, value: Int)] {
        [
            (language.secondsText(30), 30),
            (language.secondsText(60), 60),
            (language.secondsText(120), 120),
            (language.secondsText(300), 300),
            (language.secondsText(600), 600),
            (language.secondsText(900), 900),
            (language.secondsText(1800), 1800),
            (language.secondsText(3600), 3600)
        ]
    }

    // MARK: - CLOUD SYNC

    private var cloudSyncSection: some View {
        SettingsSection(title: language.text(.cloudSyncTitle), contentSpacing: 12) {
            PreferenceToggleRow(
                title: language.text(.cloudSyncEnabled),
                subtitle: language.text(.cloudSyncEnabledDescription),
                isOn: $viewModel.cloudSyncEnabled
            )

            HStack(spacing: 10) {
                Button {
                    Task { await testCloudSync() }
                } label: {
                    Label(language.text(.cloudSyncTest), systemImage: "bolt.horizontal.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!viewModel.cloudSyncEnabled || isTestingCloudSync)

                Button {
                    Task { await openDataReport() }
                } label: {
                    Label(language.text(.cloudSyncOpenData), systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isOpeningCloudData)

                if isTestingCloudSync || isOpeningCloudData {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                if let cloudSyncTestResult {
                    InlineFeedbackView(feedback: cloudSyncTestResult)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(language.dataManagementDescriptionText())
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button(role: .destructive) {
                        isConfirmingLocalDelete = true
                    } label: {
                        Label(language.deleteLocalDataText(), systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isDeletingLocalData || isDeletingRemoteData)

                    Button(role: .destructive) {
                        isConfirmingRemoteDelete = true
                    } label: {
                        Label(language.deleteRemoteDataText(), systemImage: "icloud.slash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isDeletingRemoteData)

                    if isDeletingLocalData || isDeletingRemoteData {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }

            if viewModel.cloudSyncEnabled {
                CloudSyncStatusLine(status: viewModel.cloudSyncStatus, language: language)
            }
        }
        .confirmationDialog(
            language.deleteLocalDataText(),
            isPresented: $isConfirmingLocalDelete,
            titleVisibility: .visible
        ) {
            Button(language.deleteLocalDataText(), role: .destructive) {
                deleteLocalData()
            }
            Button(role: .cancel) {
            } label: {
                Text(language.cancelText())
            }
        } message: {
            Text(language.deleteLocalDataConfirmationText())
        }
        .confirmationDialog(
            language.deleteRemoteDataText(),
            isPresented: $isConfirmingRemoteDelete,
            titleVisibility: .visible
        ) {
            Button(language.deleteRemoteDataText(), role: .destructive) {
                Task { await deleteRemoteData() }
            }
            Button(role: .cancel) {
            } label: {
                Text(language.cancelText())
            }
        } message: {
            Text(language.deleteRemoteDataConfirmationText())
        }
    }

    private func testCloudSync() async {
        isTestingCloudSync = true
        cloudSyncTestResult = nil
        do {
            try await viewModel.testCloudSync(
                endpointURL: viewModel.effectiveCloudSyncEndpointURL(),
                token: viewModel.effectiveCloudSyncToken()
            )
            cloudSyncTestResult = InlineFeedback(
                kind: .success,
                message: language.cloudSyncTestSuccessText()
            )
        } catch {
            cloudSyncTestResult = InlineFeedback(
                kind: .error,
                message: error.localizedDescription
            )
        }
        isTestingCloudSync = false
    }

    private func openDataReport() async {
        isOpeningCloudData = true
        cloudSyncTestResult = nil
        do {
            let reportURL = try await CloudSyncService.shared.makeDataReport(
                snapshot: viewModel.dataReportSnapshot(),
                endpointURLString: viewModel.effectiveCloudSyncEndpointURL(),
                token: viewModel.effectiveCloudSyncToken(),
                includeCloud: viewModel.cloudSyncEnabled
            )
            await MainActor.run {
                NSWorkspace.shared.open(reportURL)
                cloudSyncTestResult = InlineFeedback(
                    kind: .success,
                    message: language.cloudSyncReportOpenedText()
                )
            }
        } catch {
            cloudSyncTestResult = InlineFeedback(
                kind: .error,
                message: error.localizedDescription
            )
        }
        isOpeningCloudData = false
    }

    private func deleteLocalData() {
        isDeletingLocalData = true
        cloudSyncTestResult = nil
        viewModel.clearLocalUsageData()
        cloudSyncTestResult = InlineFeedback(
            kind: .success,
            message: language.localDataDeletedText()
        )
        isDeletingLocalData = false
    }

    private func deleteRemoteData() async {
        isDeletingRemoteData = true
        cloudSyncTestResult = nil
        do {
            let result = try await CloudSyncService.shared.deleteRemoteData(
                endpointURLString: viewModel.effectiveCloudSyncEndpointURL(),
                token: viewModel.effectiveCloudSyncToken()
            )
            viewModel.clearCloudUsageData()
            cloudSyncTestResult = InlineFeedback(
                kind: .success,
                message: language.remoteDataDeletedText(
                    samples: result.deletedQuotaSamples,
                    devices: result.deletedDevices
                )
            )
        } catch {
            cloudSyncTestResult = InlineFeedback(
                kind: .error,
                message: error.localizedDescription
            )
        }
        isDeletingRemoteData = false
    }

    // MARK: - QUIT

    private var quitSection: some View {
        HStack {
            Spacer()
            Button(language.text(.quitApp)) {
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

@MainActor
private struct CloudSyncStatusLine: View {
    let status: CloudSyncStatus
    let language: AppLanguage

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)

            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var dotColor: Color {
        switch status {
        case .idle: return .secondary
        case .success: return .green
        case .failure: return .red
        }
    }

    private var text: String {
        switch status {
        case .idle:
            return language.text(.cloudSyncStatusIdle)
        case .success(let date):
            let relative = Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
            return language.cloudSyncStatusSuccess(relative: relative)
        case .failure(let date, let reason, let error):
            let relative = Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
            let detail = error?.localizedDescription ?? reason.rawValue
            return language.cloudSyncStatusFailure(relative: relative, detail: detail)
        }
    }
}
