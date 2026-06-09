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
                refreshSection
                Divider()
                historySection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
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
}
