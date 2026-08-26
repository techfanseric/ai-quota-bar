import AppKit
import SwiftUI

/// General tab: app-wide system preferences.
@MainActor
struct GeneralPane: View {
    @Bindable var viewModel: UsageViewModel

    private var language: AppLanguage { viewModel.appLanguage }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                systemSection
                Divider()
                menuBarSection
                Divider()
                quitSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
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
                title: language.menuBarContentLabel(),
                subtitle: language.menuBarContentDescription(),
                selection: $viewModel.menuBarContentSelection,
                maxWidth: 160
            ) {
                ForEach(MenuBarContentSelection.allCases) { selection in
                    Text(language.menuBarContentDisplayName(selection)).tag(selection)
                }
            }

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
                title: language.menuBarRingQuotaWindowLabel(),
                subtitle: language.menuBarRingQuotaWindowDescription(),
                selection: $viewModel.menuBarRingQuotaWindow,
                maxWidth: 180
            ) {
                ForEach(MenuBarRingQuotaWindow.allCases) { window in
                    Text(language.menuBarRingQuotaWindowDisplayName(window))
                        .tag(window)
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
