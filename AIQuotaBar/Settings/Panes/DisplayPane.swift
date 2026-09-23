import SwiftUI

@MainActor
struct DisplayPane: View {
    @Bindable var viewModel: UsageViewModel
    @Bindable var service: MobileDashboardService

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
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
