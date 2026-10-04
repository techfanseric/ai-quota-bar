import AppKit
import SwiftUI

/// General tab: app-wide system preferences.
@MainActor
struct GeneralPane: View {
    @Bindable var viewModel: UsageViewModel
    @Bindable var stepAwayPreferences: StepAwayPreferences = .shared

    private var language: AppLanguage { viewModel.appLanguage }

    /// 中心节奏下拉的可选项：跟随外环 + 该 provider 实际支持的窗口。
    private func centerWindowOptions(
        for provider: UsageProvider
    ) -> [MenuBarReserveQuotaWindow] {
        [.synchronized] + provider.supportedRingWindows.compactMap {
            MenuBarReserveQuotaWindow(rawValue: $0.rawValue)
        }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                systemSection
                Divider()
                stepAwaySection
                Divider()
                menuBarSection
                Divider()
                AnonymousAnalyticsSection(analytics: .shared, language: language)
                Divider()
                quitSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private var stepAwaySection: some View {
        SettingsSection(
            title: language.stepAwaySectionTitle(),
            contentSpacing: 12
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(language.stepAwayShadeOpacityLabel())
                        .font(.body)
                    Spacer()
                    Text(language.stepAwayShadeOpacityValue(
                        stepAwayPreferences.shadeOpacityPercent))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: $stepAwayPreferences.shadeOpacityPercent,
                    in: StepAwayPreferences.opacityRange,
                    step: 5
                )
                Text(language.stepAwayShadeOpacityDescription())
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

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

            PreferenceToggleRow(
                title: language.text(.launchAtLogin),
                subtitle: language.text(.launchAtLoginDescription),
                isOn: $viewModel.launchAtLogin
            )
        }
    }

    private var menuBarSection: some View {
        SettingsSection(title: language.menuBarSectionTitle(), contentSpacing: 12) {
            PreferencePickerRow(
                title: language.menuBarAppearanceLabel(),
                subtitle: language.menuBarAppearanceDescription(),
                selection: $viewModel.menuBarAppearance,
                maxWidth: 160
            ) {
                ForEach(MenuBarAppearance.allCases) { appearance in
                    Text(language.menuBarAppearanceDisplayName(appearance)).tag(appearance)
                }
            }

            if viewModel.menuBarAppearance == .compactRing {
                ringContentControls
            } else {
                PreferencePickerRow(
                    title: language.menuBarContentLabel(),
                    subtitle: language.menuBarContentDescription(),
                    selection: $viewModel.menuBarContentSelection,
                    maxWidth: 160
                ) {
                    ForEach(MenuBarContentSelection.allCases) { selection in
                        Text(language.menuBarContentDisplayName(selection)).tag(selection)
                    }
                }
            }

            PreferencePickerRow(
                title: language.menuBarPaceDisplayModeLabel(),
                subtitle: language.menuBarPaceDisplayModeDescription(),
                selection: $viewModel.menuBarPaceDisplayMode,
                maxWidth: 180
            ) {
                ForEach(MenuBarPaceDisplayMode.allCases) { mode in
                    Text(language.menuBarPaceDisplayModeDisplayName(mode)).tag(mode)
                }
            }
            .disabled(viewModel.menuBarAppearance != .compactRing)

            PreferencePickerRow(
                title: language.menuBarTaskWaveLayoutLabel(),
                subtitle: language.menuBarTaskWaveLayoutDescription(),
                selection: $viewModel.menuBarTaskWaveLayout,
                maxWidth: 180
            ) {
                ForEach(MenuBarTaskWaveLayout.allCases) { layout in
                    Text(language.menuBarTaskWaveLayoutDisplayName(layout)).tag(layout)
                }
            }
            .disabled(viewModel.menuBarAppearance != .compactRing)

            VStack(alignment: .leading, spacing: 8) {
                Text(language.menuBarProviderRingWindowsLabel())
                    .font(.body)
                Text(language.menuBarProviderRingWindowsDescription())
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text(language.menuBarRingProviderColumnTitle())
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(language.menuBarRingOuterColumnTitle())
                            .frame(width: 120, alignment: .leading)
                        Text(language.menuBarRingCenterColumnTitle())
                            .frame(width: 120, alignment: .leading)
                    }
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
                    Divider()
                    ForEach(MenuBarRingPreferences.providerOrder) { provider in
                        HStack(spacing: 12) {
                            Text(provider.displayName)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Picker(language.menuBarRingOuterColumnTitle(), selection: Binding(
                                get: { viewModel.ringQuotaWindow(for: provider) },
                                set: { viewModel.setRingOuterWindow($0, for: provider) })) {
                                ForEach(provider.supportedRingWindows) { window in
                                    Text(language.menuBarRingQuotaWindowDisplayName(window))
                                        .tag(window)
                                }
                            }
                            .labelsHidden().pickerStyle(.menu).controlSize(.small)
                            .frame(width: 120)
                            .disabled(provider.supportedRingWindows.count < 2)
                            .accessibilityLabel(provider.displayName + " " + language.menuBarRingOuterColumnTitle())
                            Picker(language.menuBarRingCenterColumnTitle(), selection: Binding(
                                get: { viewModel.reserveQuotaWindow(for: provider) },
                                set: { viewModel.setRingCenterWindow($0, for: provider) })) {
                                ForEach(centerWindowOptions(for: provider)) { window in
                                    Text(language.menuBarReserveQuotaWindowDisplayName(window))
                                        .tag(window)
                                }
                            }
                            .labelsHidden().pickerStyle(.menu).controlSize(.small)
                            .frame(width: 120)
                            .accessibilityLabel(provider.displayName + " " + language.menuBarRingCenterColumnTitle())
                        }
                        .frame(minHeight: 30)
                    }
                }
            }
            .disabled(viewModel.menuBarAppearance != .compactRing)

            VStack(alignment: .leading, spacing: 8) {
                Text(language.menuBarCompactLayoutLabel())
                    .font(.body)
                Text(language.menuBarCompactLayoutDescription())
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                compactLayoutSlider(
                    title: language.menuBarCompactHorizontalPaddingLabel(),
                    value: $viewModel.menuBarCompactHorizontalPadding,
                    range: MenuBarCompactLayoutPreferences.horizontalPaddingRange)
                compactLayoutSlider(
                    title: language.menuBarCompactRingSpacingLabel(),
                    value: $viewModel.menuBarCompactRingSpacing,
                    range: MenuBarCompactLayoutPreferences.ringSpacingRange)
            }
            .disabled(viewModel.menuBarAppearance != .compactRing)
        }
    }

    private var ringContentControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            PreferencePickerRow(
                title: language.ringDisplayModeLabel,
                subtitle: language.ringDisplayModeDescription,
                selection: $viewModel.menuBarRingDisplayMode,
                maxWidth: 180
            ) {
                ForEach(MenuBarRingDisplayMode.allCases) { mode in
                    Text(language.ringDisplayModeName(mode)).tag(mode)
                }
            }

            HStack {
                Text(language.ringProvidersLabel)
                Spacer()
                Button(language.ringSelectAllLabel) {
                    viewModel.selectAllMenuBarRingProviders()
                }
                .disabled(viewModel.enabledMenuBarRingSelection.count == viewModel.availableMenuBarRingProviders.count)
            }
            ForEach(viewModel.availableMenuBarRingProviders, id: \.self) { provider in
                HStack {
                    Toggle(provider.displayName, isOn: Binding(
                        get: { viewModel.menuBarRingSelectedProviders.contains(provider) },
                        set: { viewModel.setMenuBarRingProvider(provider, selected: $0) }))
                        .toggleStyle(.checkbox)
                        .disabled(viewModel.enabledMenuBarRingSelection == Set([provider]))
                    if provider == .miniMax || provider == .glm {
                        Text(language.ringQuotaOnlyLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text(language.ringProvidersDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func compactLayoutSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.footnote)
                .frame(width: 92, alignment: .leading)
            Slider(value: value, in: range, step: 0.5)
            Text(String(format: "%.1f pt", value.wrappedValue))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }

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
