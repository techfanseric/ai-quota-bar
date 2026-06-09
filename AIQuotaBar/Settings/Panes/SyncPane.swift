import AppKit
import SwiftUI

/// Sync tab: built-in cloud sync, cloud data visibility, and data management.
@MainActor
struct SyncPane: View {
    @Bindable var viewModel: UsageViewModel

    @State private var syncFeedback: InlineFeedback?
    @State private var accountFeedback: InlineFeedback?
    @State private var cleanupFeedback: InlineFeedback?
    @State private var isOpeningCloudData: Bool = false
    @State private var isDeletingLocalData: Bool = false
    @State private var isDeletingRemoteData: Bool = false
    @State private var isLoadingRemoteAccounts: Bool = false
    @State private var isDeletingRemoteAccountData: Bool = false
    @State private var isConfirmingLocalDelete: Bool = false
    @State private var isConfirmingRemoteDelete: Bool = false
    @State private var isConfirmingRemoteAccountDelete: Bool = false
    @State private var isShowingAdvancedCleanup: Bool = false
    @State private var remoteAccounts: [CloudRemoteAccountSummary] = []
    @State private var selectedRemoteAccountID: String = ""

    private var language: AppLanguage { viewModel.appLanguage }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                cloudSyncSection
                Divider()
                cloudVisibilitySection
                Divider()
                accountDataSection
                Divider()
                advancedCleanupSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
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
        .confirmationDialog(
            language.deleteRemoteAccountDataText(),
            isPresented: $isConfirmingRemoteAccountDelete,
            titleVisibility: .visible
        ) {
            if let account = selectedRemoteAccount {
                Button(language.deleteRemoteAccountDataText(), role: .destructive) {
                    Task { await deleteRemoteAccountData(account) }
                }
            }
            Button(role: .cancel) {
            } label: {
                Text(language.cancelText())
            }
        } message: {
            Text(language.deleteRemoteAccountDataConfirmationText(accountName: selectedRemoteAccount?.displayAccountName ?? ""))
        }
        .task {
            if viewModel.cloudSyncEnabled, remoteAccounts.isEmpty {
                await loadRemoteAccounts()
            } else {
                selectFirstRemoteAccountIfNeeded()
            }
        }
        .onChange(of: displayedRemoteAccountIDs) { _, _ in
            selectFirstRemoteAccountIfNeeded()
        }
    }

    private var cloudSyncSection: some View {
        SettingsSection(title: language.text(.cloudSyncTitle), contentSpacing: 12) {
            PreferenceToggleRow(
                title: language.text(.cloudSyncEnabled),
                subtitle: language.text(.cloudSyncEnabledDescription),
                isOn: $viewModel.cloudSyncEnabled
            )

            PreferencePickerRow(
                title: language.cloudDataRetentionLimitLabel(),
                subtitle: language.cloudDataRetentionLimitDescription(),
                selection: $viewModel.cloudDataRetentionLimit,
                maxWidth: 160
            ) {
                ForEach(CloudDataRetentionLimit.allCases) { limit in
                    Text(language.cloudDataRetentionLimitDisplayName(limit)).tag(limit)
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task { await openDataReport() }
                } label: {
                    Label(language.text(.cloudSyncOpenData), systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isOpeningCloudData)

                if viewModel.cloudSyncEnabled {
                    CloudSyncStatusLine(status: viewModel.cloudSyncStatus, language: language)
                }

                if isOpeningCloudData {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                if let syncFeedback {
                    InlineFeedbackView(feedback: syncFeedback)
                }
            }
        }
    }

    private var cloudVisibilitySection: some View {
        SettingsSection(
            title: language.cloudVisibilitySectionTitle(),
            caption: language.cloudVisibilitySectionDescription(),
            contentSpacing: 12
        ) {
            PreferencePickerRow(
                title: language.cloudCurrentWindowVisibilityLimitLabel(),
                subtitle: language.cloudCurrentWindowVisibilityLimitDescription(),
                selection: $viewModel.cloudCurrentWindowVisibilityLimit,
                maxWidth: 160
            ) {
                ForEach(CloudDataVisibilityLimit.allCases) { limit in
                    Text(language.cloudDataVisibilityLimitDisplayName(limit)).tag(limit)
                }
            }

            PreferencePickerRow(
                title: language.cloudShortCyclesVisibilityLimitLabel(),
                subtitle: language.cloudShortCyclesVisibilityLimitDescription(),
                selection: $viewModel.cloudShortCyclesVisibilityLimit,
                maxWidth: 160
            ) {
                ForEach(CloudDataVisibilityLimit.allCases) { limit in
                    Text(language.cloudDataVisibilityLimitDisplayName(limit)).tag(limit)
                }
            }

            PreferencePickerRow(
                title: language.cloudWeeklyCyclesVisibilityLimitLabel(),
                subtitle: language.cloudWeeklyCyclesVisibilityLimitDescription(),
                selection: $viewModel.cloudWeeklyCyclesVisibilityLimit,
                maxWidth: 160
            ) {
                ForEach(CloudDataVisibilityLimit.allCases) { limit in
                    Text(language.cloudDataVisibilityLimitDisplayName(limit)).tag(limit)
                }
            }
        }
    }

    private var accountDataSection: some View {
        SettingsSection(title: language.cloudAccountDataSectionTitle(), contentSpacing: 8) {
            Text(language.deleteRemoteAccountDataDescriptionText())
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Picker("", selection: $selectedRemoteAccountID) {
                    if displayedRemoteAccounts.isEmpty {
                        Text(language.noRemoteAccountsText()).tag("")
                    } else {
                        ForEach(displayedRemoteAccounts) { account in
                            Text(remoteAccountLabel(account)).tag(account.id)
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 390)
                .disabled(displayedRemoteAccounts.isEmpty || isLoadingRemoteAccounts || isDeletingRemoteAccountData)

                Button {
                    Task { await loadRemoteAccounts() }
                } label: {
                    Label(language.refreshText(), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!viewModel.cloudSyncEnabled || isLoadingRemoteAccounts || isDeletingRemoteAccountData)

                Button(role: .destructive) {
                    isConfirmingRemoteAccountDelete = true
                } label: {
                    Label(language.deleteRemoteAccountDataText(), systemImage: "person.crop.circle.badge.xmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(selectedRemoteAccount == nil || isLoadingRemoteAccounts || isDeletingRemoteAccountData)

                if isLoadingRemoteAccounts || isDeletingRemoteAccountData {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let accountFeedback {
                InlineFeedbackView(feedback: accountFeedback)
                    .frame(maxWidth: 620, alignment: .leading)
            }
        }
    }

    private var advancedCleanupSection: some View {
        SettingsSection(title: language.advancedCleanupSectionTitle(), contentSpacing: 10) {
            DisclosureGroup(isExpanded: $isShowingAdvancedCleanup) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(language.advancedCleanupDescriptionText())
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
                        .disabled(isDeletingLocalData || isDeletingRemoteData || isDeletingRemoteAccountData)

                        Button(role: .destructive) {
                            isConfirmingRemoteDelete = true
                        } label: {
                            Label(language.deleteRemoteDataText(), systemImage: "icloud.slash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isDeletingRemoteData || isDeletingRemoteAccountData)

                        if isDeletingLocalData || isDeletingRemoteData {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    if let cleanupFeedback {
                        InlineFeedbackView(feedback: cleanupFeedback)
                            .frame(maxWidth: 620, alignment: .leading)
                    }
                }
                .padding(.top, 8)
            } label: {
                Text(language.advancedCleanupDisclosureText())
                    .font(.body)
            }
        }
    }

    private var selectedRemoteAccount: CloudRemoteAccountSummary? {
        displayedRemoteAccounts.first { $0.id == selectedRemoteAccountID }
    }

    private var displayedRemoteAccounts: [CloudRemoteAccountSummary] {
        mergeRemoteAccounts(viewModel.loadedCloudRemoteAccountSummaries(), remoteAccounts)
    }

    private var displayedRemoteAccountIDs: String {
        displayedRemoteAccounts.map(\.id).joined(separator: "|")
    }

    private func remoteAccountLabel(_ account: CloudRemoteAccountSummary) -> String {
        "\(account.provider.displayName) · \(account.displayAccountName) · \(account.modelCount) models · \(shortDateTime(account.latestSampledAt))"
    }

    private func shortDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter.string(from: date)
    }

    private func openDataReport() async {
        isOpeningCloudData = true
        syncFeedback = nil
        defer { isOpeningCloudData = false }

        do {
            let reportURL = try await CloudSyncService.shared.makeDataReport(
                snapshot: viewModel.dataReportSnapshot(),
                endpointURLString: viewModel.effectiveCloudSyncEndpointURL(),
                token: viewModel.effectiveCloudSyncToken(),
                includeCloud: viewModel.cloudSyncEnabled
            )
            NSWorkspace.shared.open(reportURL)
            syncFeedback = InlineFeedback(
                kind: .success,
                message: language.cloudSyncReportOpenedText()
            )
        } catch {
            syncFeedback = InlineFeedback(
                kind: .error,
                message: error.localizedDescription
            )
        }
    }

    private func deleteLocalData() {
        isDeletingLocalData = true
        cleanupFeedback = nil
        viewModel.clearLocalUsageData()
        cleanupFeedback = InlineFeedback(
            kind: .success,
            message: language.localDataDeletedText()
        )
        isDeletingLocalData = false
    }

    private func deleteRemoteData() async {
        isDeletingRemoteData = true
        cleanupFeedback = nil
        defer { isDeletingRemoteData = false }

        do {
            let result = try await CloudSyncService.shared.deleteRemoteData(
                endpointURLString: viewModel.effectiveCloudSyncEndpointURL(),
                token: viewModel.effectiveCloudSyncToken()
            )
            viewModel.clearCloudUsageData()
            cleanupFeedback = InlineFeedback(
                kind: .success,
                message: language.remoteDataDeletedText(
                    samples: result.deletedQuotaSamples,
                    devices: result.deletedDevices
                )
            )
        } catch {
            cleanupFeedback = InlineFeedback(
                kind: .error,
                message: error.localizedDescription
            )
        }
    }

    private func loadRemoteAccounts(clearFeedback: Bool = true) async {
        guard viewModel.cloudSyncEnabled else { return }
        isLoadingRemoteAccounts = true
        if clearFeedback {
            accountFeedback = nil
        }
        defer { isLoadingRemoteAccounts = false }

        let cachedAccounts = viewModel.loadedCloudRemoteAccountSummaries()
        if !cachedAccounts.isEmpty {
            applyRemoteAccounts(cachedAccounts)
        }
        do {
            let accounts = try await CloudSyncService.shared.fetchRemoteAccountSummaries(
                endpointURLString: viewModel.effectiveCloudSyncEndpointURL(),
                token: viewModel.effectiveCloudSyncToken()
            )
            applyRemoteAccounts(mergeRemoteAccounts(cachedAccounts, accounts))
        } catch {
            if cachedAccounts.isEmpty {
                accountFeedback = InlineFeedback(
                    kind: .error,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func applyRemoteAccounts(_ accounts: [CloudRemoteAccountSummary]) {
        remoteAccounts = accounts
        selectFirstRemoteAccountIfNeeded()
    }

    private func mergeRemoteAccounts(
        _ cachedAccounts: [CloudRemoteAccountSummary],
        _ fetchedAccounts: [CloudRemoteAccountSummary]
    ) -> [CloudRemoteAccountSummary] {
        var byID: [String: CloudRemoteAccountSummary] = [:]
        for account in cachedAccounts {
            byID[account.id] = account
        }
        for account in fetchedAccounts {
            byID[account.id] = account
        }
        return byID.values.sorted { lhs, rhs in
            if lhs.provider.rawValue != rhs.provider.rawValue {
                return lhs.provider.rawValue < rhs.provider.rawValue
            }
            if lhs.latestSampledAt != rhs.latestSampledAt {
                return lhs.latestSampledAt > rhs.latestSampledAt
            }
            return lhs.accountName.localizedStandardCompare(rhs.accountName) == .orderedAscending
        }
    }

    private func deleteRemoteAccountData(_ account: CloudRemoteAccountSummary) async {
        isDeletingRemoteAccountData = true
        accountFeedback = nil
        defer { isDeletingRemoteAccountData = false }

        do {
            let result = try await CloudSyncService.shared.deleteRemoteAccountData(
                provider: account.provider,
                accountName: account.accountName,
                endpointURLString: viewModel.effectiveCloudSyncEndpointURL(),
                token: viewModel.effectiveCloudSyncToken()
            )
            accountFeedback = InlineFeedback(
                kind: .success,
                message: language.remoteAccountDataDeletedText(
                    accountName: account.displayAccountName,
                    samples: result.deletedQuotaSamples
                )
            )
            viewModel.clearCloudUsageData(for: account.accountName)
            remoteAccounts.removeAll { summary in
                normalizedAccountName(summary.accountName) == normalizedAccountName(account.accountName)
            }
            selectFirstRemoteAccountIfNeeded()
            await viewModel.reloadCloudUsageData()
            await loadRemoteAccounts(clearFeedback: false)
        } catch {
            accountFeedback = InlineFeedback(
                kind: cloudAccountDeleteFeedbackKind(error),
                message: cloudAccountDeleteErrorText(error)
            )
        }
    }

    private func cloudAccountDeleteFeedbackKind(_ error: Error) -> InlineFeedback.Kind {
        if case CloudSyncError.serverError(404, _) = error {
            return .warning
        }
        return .error
    }

    private func cloudAccountDeleteErrorText(_ error: Error) -> String {
        if case CloudSyncError.serverError(404, _) = error {
            return language.cloudAccountDeleteUnavailableText()
        }
        return error.localizedDescription
    }

    private func selectFirstRemoteAccountIfNeeded() {
        let accounts = displayedRemoteAccounts
        if !accounts.contains(where: { $0.id == selectedRemoteAccountID }) {
            selectedRemoteAccountID = accounts.first?.id ?? ""
        }
    }

    private func normalizedAccountName(_ accountName: String) -> String {
        accountName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
            return language.cloudSyncStatusSuccess(relative: Self.relativeFormatter.localizedString(for: date, relativeTo: Date()))
        case .failure(let date, _, let error):
            return language.cloudSyncStatusFailure(
                relative: Self.relativeFormatter.localizedString(for: date, relativeTo: Date()),
                detail: error?.localizedDescription ?? ""
            )
        }
    }
}
