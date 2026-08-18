import SwiftUI

/// Usage tab: refresh cadence, warning threshold, and local history behavior.
@MainActor
struct UsagePane: View {
    @Bindable var viewModel: UsageViewModel

    private var language: AppLanguage { viewModel.appLanguage }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                quotaWarningSection
                Divider()
                leftClickMenuSection
                Divider()
                refreshSection
                Divider()
                historySection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private var leftClickMenuSection: some View {
        SettingsSection(
            title: language.leftClickMenuDisplayTitle(),
            caption: language.leftClickMenuDisplayDescription(),
            contentSpacing: 10
        ) {
            HStack {
                Text(language.leftClickMenuVisibleCount(
                    visible: visibleLeftClickMenuModelCount,
                    total: leftClickMenuModelCount))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(language.leftClickMenuShowAll()) {
                    viewModel.showAllLeftClickMenuItems()
                }
                .controlSize(.small)
                .disabled(!viewModel.hasHiddenLeftClickMenuItems)
            }

            if leftClickMenuProviderGroups.isEmpty {
                Text(language.leftClickMenuModelsEmpty())
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(leftClickMenuProviderGroups) { providerGroup in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(providerGroup.provider.displayName)
                            .font(.subheadline.weight(.semibold))

                        ForEach(providerGroup.accounts) { accountGroup in
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle(
                                    isOn: leftClickMenuAccountBinding(
                                        accountGroup.key)
                                ) {
                                    HStack {
                                        Text(accountGroup.displayName)
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(accountGroup.models.count)")
                                            .font(.footnote.monospacedDigit())
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .toggleStyle(.checkbox)

                                VStack(alignment: .leading, spacing: 5) {
                                    ForEach(accountGroup.models) { model in
                                        Toggle(
                                            isOn: leftClickMenuModelBinding(model)
                                        ) {
                                            HStack {
                                                Text(model.modelName)
                                                    .lineLimit(1)
                                                Spacer()
                                                Text(model.currentIntervalRemainingText)
                                                    .font(.footnote.monospacedDigit())
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .toggleStyle(.checkbox)
                                        .disabled(
                                            !viewModel.isLeftClickMenuAccountVisible(
                                                accountGroup.key))
                                    }
                                }
                                .padding(.leading, 20)
                            }
                        }
                    }
                }
            }
        }
    }

    private var quotaWarningSection: some View {
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
        }
    }

    private var refreshSection: some View {
        SettingsSection(title: language.usageRefreshSectionTitle(), contentSpacing: 12) {
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
        }
    }

    private var historySection: some View {
        SettingsSection(title: language.usageHistorySectionTitle(), contentSpacing: 12) {
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

    private var leftClickMenuModels: [ModelUsageData] {
        var seen = Set<MobileDashboardModelSelectionKey>()
        return viewModel.providerUsageSections
            .flatMap(\.models)
            .filter { seen.insert($0.mobileDashboardSelectionKey).inserted }
    }

    private var leftClickMenuModelCount: Int {
        leftClickMenuModels.count
    }

    private var visibleLeftClickMenuModelCount: Int {
        leftClickMenuModels.filter(viewModel.isLeftClickMenuModelVisible).count
    }

    private var leftClickMenuProviderGroups: [LeftClickMenuProviderGroup] {
        var groups: [LeftClickMenuProviderGroup] = []
        for model in leftClickMenuModels {
            let providerIndex: Int
            if let existing = groups.firstIndex(where: { $0.provider == model.provider }) {
                providerIndex = existing
            } else {
                groups.append(LeftClickMenuProviderGroup(provider: model.provider, accounts: []))
                providerIndex = groups.count - 1
            }

            let key = LeftClickMenuAccountKey(model: model)
            if let accountIndex = groups[providerIndex].accounts.firstIndex(where: { $0.key == key }) {
                groups[providerIndex].accounts[accountIndex].models.append(model)
            } else {
                let trimmedAccount = model.accountName?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                groups[providerIndex].accounts.append(
                    LeftClickMenuAccountGroup(
                        key: key,
                        displayName: trimmedAccount.flatMap { $0.isEmpty ? nil : $0 }
                            ?? language.leftClickMenuDefaultAccount(),
                        models: [model]))
            }
        }
        return groups
    }

    private func leftClickMenuAccountBinding(
        _ key: LeftClickMenuAccountKey
    ) -> Binding<Bool> {
        Binding(
            get: { viewModel.isLeftClickMenuAccountVisible(key) },
            set: { viewModel.setLeftClickMenuAccountVisible($0, key: key) })
    }

    private func leftClickMenuModelBinding(
        _ model: ModelUsageData
    ) -> Binding<Bool> {
        Binding(
            get: { viewModel.isLeftClickMenuModelVisible(model) },
            set: { viewModel.setLeftClickMenuModelVisible($0, model: model) })
    }
}

private struct LeftClickMenuProviderGroup: Identifiable {
    let provider: UsageProvider
    var accounts: [LeftClickMenuAccountGroup]

    var id: UsageProvider { provider }
}

private struct LeftClickMenuAccountGroup: Identifiable {
    let key: LeftClickMenuAccountKey
    let displayName: String
    var models: [ModelUsageData]

    var id: LeftClickMenuAccountKey { key }
}
