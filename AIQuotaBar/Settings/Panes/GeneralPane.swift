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
