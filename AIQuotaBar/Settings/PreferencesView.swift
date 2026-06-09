import AppKit
import SwiftUI

/// 顶层 Preferences 容器：3 tab（General / Providers / About），窗口固定 792x638，
/// 不随 tab 切换 resize。
@MainActor
struct PreferencesView: View {
    @Bindable var viewModel: UsageViewModel
    @State private var selection = PreferencesSelection()

    var body: some View {
        TabView(selection: $selection.tab) {
            GeneralPane(viewModel: viewModel)
                .tabItem {
                    Label(viewModel.appLanguage.text(.tabGeneral),
                          systemImage: PreferencesTab.general.systemImage)
                }
                .tag(PreferencesTab.general)

            UsagePane(viewModel: viewModel)
                .tabItem {
                    Label(viewModel.appLanguage.text(.tabUsage),
                          systemImage: PreferencesTab.usage.systemImage)
                }
                .tag(PreferencesTab.usage)

            SyncPane(viewModel: viewModel)
                .tabItem {
                    Label(viewModel.appLanguage.text(.tabSync),
                          systemImage: PreferencesTab.sync.systemImage)
                }
                .tag(PreferencesTab.sync)

            ProvidersPane(viewModel: viewModel)
                .tabItem {
                    Label(viewModel.appLanguage.text(.tabProviders),
                          systemImage: PreferencesTab.providers.systemImage)
                }
                .tag(PreferencesTab.providers)

            AboutPane(viewModel: viewModel)
                .tabItem {
                    Label(viewModel.appLanguage.text(.tabAbout),
                          systemImage: PreferencesTab.about.systemImage)
                }
                .tag(PreferencesTab.about)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(width: PreferencesTab.providersWidth, height: PreferencesTab.windowHeight)
    }
}
