import SwiftUI

@MainActor
struct DisplayPane: View {
    @Bindable var viewModel: UsageViewModel
    @Bindable var service: MobileDashboardService

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSection(
                    title: viewModel.appLanguage.followRunningAppsSectionTitle,
                    contentSpacing: 12
                ) {
                    PreferenceToggleRow(
                        title: viewModel.appLanguage.followRunningAppsLabel,
                        subtitle: viewModel.appLanguage.followRunningAppsDescription,
                        isOn: $viewModel.followRunningApps)
                }
                Divider()
                SettingsSection(
                    title: viewModel.appLanguage.menuBarPlaceholderSectionTitle,
                    contentSpacing: 12
                ) {
                    PreferencePickerRow(
                        title: viewModel.appLanguage.menuBarPlaceholderStyleLabel,
                        subtitle: viewModel.appLanguage.menuBarPlaceholderStyleDescription,
                        selection: $viewModel.menuBarPlaceholderStyle,
                        maxWidth: 180
                    ) {
                        ForEach(MenuBarPlaceholderStyle.allCases) { style in
                            Text(viewModel.appLanguage.menuBarPlaceholderStyleDisplayName(style))
                                .tag(style)
                        }
                    }
                }
                Divider()
                LeftClickMenuProviderOrderSection(
                    language: viewModel.appLanguage,
                    preferences: $viewModel.leftClickMenuDisplayPreferences)
                ModelDisplaySettings(
                    models: viewModel.providerUsageSections.flatMap(\.models),
                    language: viewModel.appLanguage,
                    menuPreferences: $viewModel.leftClickMenuDisplayPreferences,
                    chartPreferences: $viewModel.quotaChartDisplayPreferences,
                    service: service)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
    }
}
