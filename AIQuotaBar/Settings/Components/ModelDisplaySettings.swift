import SwiftUI

/// Shared model matrix. Bindings retain the existing persistence and delivery
/// paths; mobile limits continue to be enforced by MobileDashboardService.
@MainActor
struct ModelDisplaySettings: View {
    let models: [ModelUsageData]
    let language: AppLanguage
    @Binding var menuPreferences: LeftClickMenuDisplayPreferences
    @Binding var chartPreferences: QuotaChartDisplayPreferences
    @Bindable var service: MobileDashboardService

    private var catalog: ModelDisplayCatalog { ModelDisplayCatalog(models: models) }
    private var mobileKeys: [MobileDashboardModelSelectionKey] { catalog.models.map(\.mobileDashboardSelectionKey) }
    private var unavailable: [MobileDashboardModelSelectionKey] { catalog.unavailableSelections(service.selectedModelKeys) }
    private func t(_ zh: String, _ en: String) -> String { language == .simplifiedChinese ? zh : en }
    private let toggleWidth: CGFloat = 76
    private let chartWidth: CGFloat = 132

    var body: some View {
        SettingsSection(title: language.modelDisplayTitle(),
            caption: t("每个模型只需设置一次，分别控制菜单、手机看板和额度图表。", "Set menu visibility, mobile selection and quota chart style in one place."), contentSpacing: 12) {
            HStack(spacing: 16) {
                Text(t("菜单", "Menu") + " · " + language.leftClickMenuVisibleCount(
                    visible: catalog.models.filter(menuPreferences.isModelVisible).count, total: catalog.models.count))
                Text(t("手机", "Mobile") + " · " + language.mobileDashboardModelsSelectedCount(
                    service.selectedModelKeys.count, maximum: MobileDashboardService.maximumSelectedModelCount))
                Spacer(minLength: 0)
                Button(t("菜单全部显示", "Show all in menu")) { menuPreferences.showAll() }
                    .controlSize(.small).disabled(!menuPreferences.hasHiddenItems)
            }
            .font(.footnote).foregroundStyle(.secondary)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(t("账号 / 模型", "Account / Model")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(t("左键菜单", "Menu")).frame(width: toggleWidth)
                    Text(t("手机看板", "Mobile")).frame(width: toggleWidth)
                    Text(t("图表样式", "Chart style")).frame(width: chartWidth, alignment: .leading)
                        .help(language.quotaChartDisplayDescription())
                }
                .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                Divider()
                ForEach(catalog.accounts) { account in
                    accountRows(account)
                }
                if catalog.models.isEmpty {
                    Text(language.mobileDashboardModelsEmpty())
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 16)
                }
                if !unavailable.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(language.mobileDashboardUnavailableModelsTitle()).font(.subheadline.weight(.medium))
                        Text(language.mobileDashboardUnavailableModelsDescription()).font(.footnote).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                    ForEach(unavailable, id: \.self) { key in unavailableRow(key) }
                }
            }
            Text(t("账号行的菜单开关会保留各模型的选择。手机看板保留 1–2 项；图表选“自动”沿用默认规则。隐藏不影响采集、历史、告警或同步。",
                "Account switches preserve individual menu choices. Select 1–2 models for mobile; Automatic uses the default chart rules. Hiding items does not affect collection, history, alerts or sync."))
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { service.initializeModelSelectionIfNeeded(candidates: catalog.models) }
        .onChange(of: mobileKeys) { _, _ in service.initializeModelSelectionIfNeeded(candidates: catalog.models) }
    }

    private func accountRows(_ account: ModelDisplayCatalog.Account) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(account.provider.displayName + " · " + (account.name.isEmpty ? language.leftClickMenuDefaultAccount() : account.name))
                    .font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    .help(account.name).frame(maxWidth: .infinity, alignment: .leading)
                Toggle(t("账号菜单总开关", "Show account in menu"), isOn: Binding(
                    get: { menuPreferences.isAccountVisible(account.key) },
                    set: { menuPreferences.setAccountVisible($0, key: account.key) }))
                    .labelsHidden().toggleStyle(.checkbox).frame(width: toggleWidth)
                    .accessibilityLabel(account.provider.displayName + " " + account.name + " " + t("账号菜单总开关", "Show account in menu"))
                    .help(t("隐藏整个账号，保留下面各模型的选择。", "Hide this account while preserving its individual model choices."))
                Color.clear.frame(width: toggleWidth, height: 1).accessibilityHidden(true)
                Color.clear.frame(width: chartWidth, height: 1).accessibilityHidden(true)
            }.padding(.top, 12).padding(.bottom, 6)
            ForEach(account.models, id: \.mobileDashboardSelectionKey) { model in
                HStack(spacing: 12) {
                    Text(model.modelName).lineLimit(1).help(model.modelName)
                        .padding(.leading, 12).frame(maxWidth: .infinity, alignment: .leading)
                    Toggle(t("在菜单显示", "Show in menu"), isOn: Binding(
                        get: { menuPreferences.isModelVisible(model) },
                        set: { menuPreferences.setModelVisible($0, key: model.mobileDashboardSelectionKey) }))
                        .labelsHidden().toggleStyle(.checkbox).frame(width: toggleWidth)
                        .disabled(!menuPreferences.isAccountVisible(account.key))
                        .accessibilityLabel(accessibilityName(model) + " " + t("在菜单显示", "Show in menu"))
                    mobileToggle(model.mobileDashboardSelectionKey, label: accessibilityName(model))
                    Picker(t("图表样式", "Chart style"), selection: Binding(
                        get: { chartPreferences.mode(for: model) },
                        set: { chartPreferences.setMode($0, for: model) })) {
                        ForEach(QuotaChartDisplayMode.allCases) { mode in
                            Text(language.quotaChartDisplayModeName(mode)).tag(mode)
                        }
                    }.labelsHidden().pickerStyle(.menu).controlSize(.small).frame(width: chartWidth)
                        .accessibilityLabel(accessibilityName(model) + " " + t("图表样式", "Chart style"))
                }.frame(minHeight: 30)
            }
            Divider().padding(.top, 8)
        }
    }

    private func unavailableRow(_ key: MobileDashboardModelSelectionKey) -> some View {
        let provider = UsageProvider(rawValue: key.providerRaw)?.displayName ?? key.providerRaw
        let account = key.normalizedAccount.isEmpty ? language.mobileDashboardDefaultAccount() : key.normalizedAccount
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(key.normalizedModel).lineLimit(1)
                Text(provider + " · " + account).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text("—").foregroundStyle(.tertiary).frame(width: toggleWidth)
            mobileToggle(key, label: provider + " " + account + " " + key.normalizedModel)
            Text(language.mobileDashboardUnavailableBadge()).font(.footnote).foregroundStyle(.secondary)
                .frame(width: chartWidth, alignment: .leading)
        }.padding(.vertical, 6)
    }

    private func mobileToggle(_ key: MobileDashboardModelSelectionKey, label: String) -> some View {
        Toggle(t("在手机显示", "Show on mobile"), isOn: Binding(
            get: { service.selectedModelKeys.contains(key) },
            set: { selected in
                if selected != service.selectedModelKeys.contains(key) { _ = service.toggleModelSelection(key) }
            }))
            .labelsHidden().toggleStyle(.checkbox).frame(width: toggleWidth)
            .disabled(selectionDisabled(key)).help(selectionHelp(key))
            .accessibilityLabel(label + " " + t("在手机显示", "Show on mobile"))
            .accessibilityHint(selectionHelp(key))
    }

    private func selectionDisabled(_ key: MobileDashboardModelSelectionKey) -> Bool {
        service.selectedModelKeys.contains(key)
            ? service.selectedModelKeys.count <= 1
            : service.selectedModelKeys.count >= MobileDashboardService.maximumSelectedModelCount
    }
    private func selectionHelp(_ key: MobileDashboardModelSelectionKey) -> String {
        guard selectionDisabled(key) else { return language.mobileDashboardModelSelectionHint() }
        return service.selectedModelKeys.contains(key)
            ? language.mobileDashboardAtLeastOneModelRequired() : language.mobileDashboardDeselectModelFirst()
    }
    private func accessibilityName(_ model: ModelUsageData) -> String {
        language.mobileDashboardModelAccessibilityLabel(provider: model.provider.displayName,
            account: model.accountName ?? language.leftClickMenuDefaultAccount(), model: model.modelName)
    }
}
