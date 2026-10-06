import AppKit
import CodexBarCore
import SwiftUI

struct MenuView: View {
    @State private var showsUsagePreview = false
    @State private var updates = UpdateChecker.shared
    @Bindable var viewModel: UsageViewModel
    @Bindable var presentationSizing: MenuPresentationSizing
    var onOpenSettings: () -> Void
    var onLayoutChange: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    modelsList
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: presentationSizing.maximumScrollableHeight)

            Divider()
                .padding(.vertical, 4)
            footer
        }
        .padding(10)
        .frame(width: MenuBarPanelLayout.width)
        .task { await updates.checkIfNeeded() }
        .onChange(of: showsUsagePreview) { _, _ in onLayoutChange() }
    }

    private var language: AppLanguage {
        viewModel.appLanguage
    }

    @ViewBuilder
    private var modelsList: some View {
        let sections = viewModel.leftClickMenuUsageSections
        if sections.isEmpty && !viewModel.hasAnyCredential && !viewModel.cloudSyncEnabled {
            VStack(alignment: .leading, spacing: 10) {
                Text(language == .simplifiedChinese ? "从一个供应商开始" : "Start with one provider")
                    .font(.system(size: 12, weight: .semibold))
                Text(language == .simplifiedChinese ? "连接后，在这里查看额度、趋势和本机用量。Codex 可沿用本机登录；其他供应商按需添加。" : "Connect to see quotas, trends and local usage here. Codex uses your local sign-in; other providers are optional.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(language == .simplifiedChinese ? "连接供应商" : "Connect a provider", action: onOpenSettings)
                    Button(language == .simplifiedChinese ? (showsUsagePreview ? "收起示例" : "先看示例") : (showsUsagePreview ? "Hide preview" : "Preview first")) { showsUsagePreview.toggle() }
                }.controlSize(.small).tint(.primary)
                if showsUsagePreview { LocalUsageSamplePreview(language: language) }
            }.padding(8)
        } else if sections.isEmpty && !viewModel.hasAnyCredential && viewModel.cloudSyncEnabled {
            MenuPlaceholderCard(
                icon: "icloud",
                title: language == .simplifiedChinese ? "等待云端记录" : "Waiting for cloud history",
                message: (language == .simplifiedChinese ? "云同步已配置，无需添加本机供应商。正在读取历史记录。" : "Cloud sync is configured; no local provider is required. Loading history."),
                primaryActionTitle: language.text(.refresh),
                primaryAction: { Task { await viewModel.refresh(showIconSelfTest: false) } },
                secondaryActionTitle: language.text(.settings),
                secondaryAction: onOpenSettings)
        } else if !sections.isEmpty {
            VStack(spacing: 0) {
                let providerCount = Set(sections.map(\.provider)).count
                HStack(spacing: 8) {
                    Text("\(providerCount) Providers · \(sections.map(\.modelCount).reduce(0, +)) Models")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    if let lastRefresh = viewModel.lastRefreshTime {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(language.updatedAgoText(from: lastRefresh, now: context.date))
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }

                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Image(systemName: viewModel.isLoading ? "hourglass" : "arrow.clockwise")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isLoading)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 8)

                ForEach(Array(sections.enumerated()), id: \.offset) { _, data in
                    ProviderModelsSection(
                        data: data,
                        language: language,
                        warningThreshold: viewModel.effectiveWarningThreshold,
                        samples: viewModel.samples(for:),
                        viewModel: viewModel,
                        isCollapsed: viewModel.isProviderCollapsed(data.provider),
                        onToggleCollapse: {
                            viewModel.toggleProviderCollapsed(data.provider)
                            onLayoutChange()
                        },
                        onLayoutChange: onLayoutChange
                    )
                }

                let visibleProviders = Set(sections.map(\.provider))
                let visibleProviderErrors = UsageProvider.allCases.filter {
                    viewModel.providerErrors[$0] != nil && !visibleProviders.contains($0)
                }
                if !visibleProviderErrors.isEmpty {
                    Divider()
                        .padding(.vertical, 4)

                    ForEach(visibleProviderErrors) { provider in
                        if let error = viewModel.providerErrors[provider] {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("\(provider.displayName): \(language.errorDescription(for: error))")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        } else if viewModel.hasHiddenLeftClickMenuItems,
                  !viewModel.providerUsageSections.isEmpty {
            MenuPlaceholderCard(
                icon: "eye.slash.fill",
                title: language.leftClickMenuAllHiddenTitle(),
                message: language.leftClickMenuAllHiddenDescription(),
                primaryActionTitle: language.text(.settings),
                primaryAction: onOpenSettings
            )
        } else if shouldShowCodexEmptyState {
            MenuPlaceholderCard(
                icon: "terminal.fill",
                title: language == .simplifiedChinese ? "等待 Codex" : "Waiting for Codex",
                message: language == .simplifiedChinese ? "打开 Codex 后会自动获取额度。本机历史仍可在设置 → 用量中查看。" : "Open Codex to refresh your quota. Local history remains available in Settings → Usage.",
                primaryActionTitle: language.text(.settings),
                primaryAction: onOpenSettings
            )
        } else if viewModel.allConfiguredProvidersPaused {
            MenuPlaceholderCard(
                icon: "pause.circle.fill",
                title: language.providerPausedStatus(),
                message: language.allProvidersPausedDescription(),
                primaryActionTitle: language.text(.settings),
                primaryAction: onOpenSettings
            )
        } else if !viewModel.hasAPIKey {
            MenuPlaceholderCard(
                icon: "key.fill",
                title: language.text(.errorNotConfigured),
                message: language.text(.menuConfigureKeyHint),
                primaryActionTitle: language.text(.settings),
                primaryAction: onOpenSettings
            )
        } else if viewModel.isLoading || (viewModel.usageData == nil && viewModel.error == nil) {
            MenuPlaceholderCard(
                icon: "hourglass",
                title: language.text(.loading),
                message: language.text(.menuLoadingHint),
                showsSpinner: true
            )
        } else if let error = viewModel.error {
            MenuPlaceholderCard(
                icon: "exclamationmark.triangle.fill",
                title: language.errorDescription(for: error),
                message: language.text(.menuRefreshHint),
                primaryActionTitle: language.text(.refresh),
                primaryAction: {
                    Task { await viewModel.refresh() }
                },
                secondaryActionTitle: language.text(.settings),
                secondaryAction: onOpenSettings
            )
        } else {
            MenuPlaceholderCard(
                icon: "tray.fill",
                title: language.text(.models),
                message: language.text(.menuEmptyModelsHint),
                primaryActionTitle: language.text(.refresh),
                primaryAction: {
                    Task { await viewModel.refresh() }
                }
            )
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button(action: onOpenSettings) {
                Text("Settings")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            if let release = updates.availableRelease {
                Button { NSWorkspace.shared.open(release.changelogURL) } label: {
                    Text(language == .simplifiedChinese ? "新版 \(release.version) ↗" : "Update \(release.version) ↗")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help(language == .simplifiedChinese ? "查看更新日志与下载新版" : "View release notes and download")
            }

            Spacer(minLength: 4)

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }

    /// 当 Codex 是唯一已配置且尚未拉到数据时，触发 codex 专属占位
    /// （避免退化成通用的 "API key not configured" 提示）。
    private var shouldShowCodexEmptyState: Bool {
        !viewModel.isLoading
            && viewModel.error == nil
            && viewModel.usageData == nil
            && viewModel.configuredProviders == [.codex]
    }
}

@MainActor
@Observable
final class MenuPresentationSizing {
    var maximumScrollableHeight: CGFloat

    init(maximumScrollableHeight: CGFloat) {
        self.maximumScrollableHeight = maximumScrollableHeight
    }
}

private struct MenuPlaceholderCard: View {
    let icon: String
    let title: String
    let message: String
    var primaryActionTitle: String? = nil
    var primaryAction: (() -> Void)? = nil
    var secondaryActionTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil
    var showsSpinner: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: 28, height: 28)

                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)

                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if showsSpinner {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if primaryActionTitle != nil || secondaryActionTitle != nil {
                HStack(spacing: 8) {
                    if let primaryActionTitle, let primaryAction {
                        Button(action: primaryAction) {
                            Text(primaryActionTitle)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }

                    if let secondaryActionTitle, let secondaryAction {
                        Button(action: secondaryAction) {
                            Text(secondaryActionTitle)
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

private struct ProviderModelsSection: View {
    let data: UsageData
    let language: AppLanguage
    let warningThreshold: Double
    let samples: (ModelUsageData) -> [ModelQuotaSample]
    let viewModel: UsageViewModel
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void
    let onLayoutChange: () -> Void

    @State private var showsFullQuotaModels = false
    @State private var showsExhaustedModels = false
    /// 账号分组折叠状态的用户覆盖；未覆盖时默认「当前账号展开、其余收起」，
    /// 切换登录账号后清空，让默认规则对新账号重新生效。
    @State private var accountCollapseOverrides: [String: Bool] = [:]

    private var visibleModels: [ModelUsageData] {
        return sortedMenuModels(data.models).filter {
            isVisibleInlineModel($0)
        }
    }

    private var curveModelIDs: Set<String> {
        let renderableModelIDs = Set(data.models
            .filter(hasRenderableCurrentWindow(for:))
            .map(\.id))
        return QuotaCurveModelSelector.curveModelIDs(
            in: data.models,
            renderableModelIDs: renderableModelIDs,
            preferences: viewModel.quotaChartDisplayPreferences)
    }

    private var exhaustedModels: [ModelUsageData] {
        return sortedMenuModels(data.models).filter {
            hasVisibleContent(for: $0) && !isVisibleInlineModel($0) && $0.isExhaustedCurrentInterval
        }
    }

    private var fullQuotaModels: [ModelUsageData] {
        return sortedMenuModels(data.models).filter {
            hasVisibleContent(for: $0) && !isVisibleInlineModel($0) && $0.isFullQuotaUnused
        }
    }

    /// 按 `accountName` 分组（nil/空归入 nil bucket）。
    /// 返回的顺序：本机/Mix 账号优先；Cloud-only 账号按最近采样时间倒序；nil 桶最后。
    private var groupedVisibleModels: [AccountModelGroup] {
        let named = Dictionary(grouping: visibleModels) { model -> String? in
            guard let account = model.accountName, !account.isEmpty else { return nil }
            return account
        }

        return named
            .map { accountName, models in
                AccountModelGroup(accountName: accountName, models: sortedMenuModels(models))
            }
            .sorted { isAccountGroup($0, orderedBefore: $1) }
    }

    private struct AccountModelGroup {
        let accountName: String?
        let models: [ModelUsageData]
    }

    private func isVisibleInlineModel(_ model: ModelUsageData) -> Bool {
        guard hasVisibleContent(for: model) else { return false }
        if curveModelIDs.contains(model.id), !model.isShortCurrentInterval {
            return true
        }
        if model.isFullQuotaUnused {
            return true
        }
        if !hasRenderableCurrentWindow(for: model) {
            return true
        }
        return !model.isExhaustedCurrentInterval && !model.isFullQuotaUnused
    }

    private func hasVisibleContent(for model: ModelUsageData) -> Bool {
        hasRenderableCurrentWindow(for: model) || !utilizationCycles(for: model).isEmpty
    }

    private func hasRenderableCurrentWindow(for model: ModelUsageData) -> Bool {
        if isCloudModel(model),
           let sampledAt = model.sampledAt,
           let interval = viewModel.cloudCurrentWindowVisibilityLimit.interval,
           Date().timeIntervalSince(sampledAt) > interval {
            return false
        }
        guard let startTime = model.startTime, let endTime = model.endTime else { return true }
        let now = Date()
        return startTime <= now && now <= endTime
    }

    private func utilizationCycles(for model: ModelUsageData) -> [(resetsAt: Date, peakPercent: Double)] {
        let limit = model.isShortCurrentInterval ? 30 : 12
        let cycles = viewModel.utilizationCycles(for: model, limit: limit)
        return filteredCloudCycles(cycles, for: model)
    }

    private func filteredCloudCycles(
        _ cycles: [(resetsAt: Date, peakPercent: Double)],
        for model: ModelUsageData
    ) -> [(resetsAt: Date, peakPercent: Double)] {
        guard isCloudModel(model) else { return cycles }
        let limit = model.isShortCurrentInterval
            ? viewModel.cloudShortCyclesVisibilityLimit
            : viewModel.cloudWeeklyCyclesVisibilityLimit
        guard let interval = limit.interval else { return cycles }
        let now = Date()
        return cycles.filter { cycle in
            now.timeIntervalSince(cycle.resetsAt) <= interval
        }
    }

    private func isCloudModel(_ model: ModelUsageData) -> Bool {
        model.parsedDetail.source == "Cloud"
    }

    private func isAccountGroup(_ lhs: AccountModelGroup, orderedBefore rhs: AccountModelGroup) -> Bool {
        let lhsAccountPriority = lhs.accountName == nil ? 1 : 0
        let rhsAccountPriority = rhs.accountName == nil ? 1 : 0
        if lhsAccountPriority != rhsAccountPriority {
            return lhsAccountPriority < rhsAccountPriority
        }

        let lhsSourcePriority = accountSourcePriority(lhs.models)
        let rhsSourcePriority = accountSourcePriority(rhs.models)
        if lhsSourcePriority != rhsSourcePriority {
            return lhsSourcePriority < rhsSourcePriority
        }

        if lhsSourcePriority > 0 {
            let lhsDate = lhs.models.compactMap(\.sampledAt).max() ?? .distantPast
            let rhsDate = rhs.models.compactMap(\.sampledAt).max() ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
        }

        return (lhs.accountName ?? "").localizedStandardCompare(rhs.accountName ?? "") == .orderedAscending
    }

    private func accountSourcePriority(_ models: [ModelUsageData]) -> Int {
        models.contains { model in
            let source = model.parsedDetail.source ?? ""
            return source != "Cloud"
        } ? 0 : 1
    }

    var body: some View {
        let currentUsage = CodexLocalUsageModel.shared
        let currentName = currentUsage.currentAccountID.flatMap { currentUsage.accountLabels[$0] }
        let originalGroups = groupedVisibleModels
        let currentIndex = data.provider == .codex ? originalGroups.firstIndex {
            guard let name = currentName, let account = $0.accountName else { return false }
            return name.caseInsensitiveCompare(account) == .orderedSame
        } : nil
        let groups = currentIndex.map { index in
            [originalGroups[index]] + originalGroups.enumerated().filter { $0.offset != index }.map(\.element)
        } ?? originalGroups
        VStack(alignment: .leading, spacing: 0) {
            providerHeader()
            if !isCollapsed {
            if data.provider == .glm, let resets = data.glmResetAllowances {
                let fiveHour = resets.availableFiveHour()
                let weekly = resets.availableWeekly()
                VStack(alignment: .leading, spacing: 3) {
                    Text(language == .simplifiedChinese
                         ? "可用重置 · 5h \(fiveHour.count) 次 · 周 \(weekly.count) 次"
                         : "Available resets · 5h ×\(fiveHour.count) · Weekly ×\(weekly.count)")
                        .font(.system(size: 10, weight: .medium))
                    if let expiry = (fiveHour + weekly).min() {
                        Text((language == .simplifiedChinese ? "最近到期：" : "Next expiry: ")
                             + expiry.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            if data.provider == .codex {
                if currentIndex != nil, let first = groups.first {
                    accountHeader(first, isCurrent: true)
                } else {
                    accountHeader(AccountModelGroup(accountName: currentName, models: []), isCurrent: true)
                }
                if !(currentIndex != nil && isAccountCollapsed(groups[0], isCurrent: true)) {
                    CodexLocalUsageMenuCard(model: .shared, language: language)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                if data.models.isEmpty {
                    Text(language == .simplifiedChinese ? "账号额度尚未就绪，可在设置中连接账号。" : "Account quota unavailable. Connect an account in Settings.")
                        .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 8)
                }
            }

            ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, group in
                let rows = group.models
                let isCurrentGroup = data.provider == .codex && currentIndex != nil && groupIndex == 0
                // 账号名为空的分组不画账号头。那一行的内容退化成「来源词 + Unknown
                // account」—— 来源词上方标题里已经有了，而 "Unknown account" 只是
                // 把"没名字"这件事重复一遍。整行零信息量，纯噪音。
                // Codex 的分组本来就按账号名分（空的已被过滤），所以这条只影响
                // GLM / MiniMax / Kimi 这些账号名可空的供应商。
                let hasAccountName = !(group.accountName ?? "").isEmpty
                if hasAccountName,
                   data.provider != .codex || currentIndex == nil || groupIndex != 0 {
                    accountHeader(group, isCurrent: false)
                }
                if !isAccountCollapsed(group, isCurrent: isCurrentGroup) {
                    if data.provider == .codex, selectableCycles(group).count > 1 {
                        accountCycleSwitcher(group)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, model in
                        ModelRow(
                            model: model,
                            language: language,
                            warningThreshold: warningThreshold,
                            samples: samples(model),
                            rendersAreaChart: curveModelIDs.contains(model.id),
                            viewModel: viewModel
                        )

                        if !(index == rows.count - 1 && groupIndex == groups.count - 1) {
                            Spacer()
                                .frame(height: 1)
                        }
                    }
                }
            }

            if visibleModels.isEmpty && exhaustedModels.isEmpty && !fullQuotaModels.isEmpty && !showsFullQuotaModels {
                Text(language.allModelsUnusedText())
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }

            if !exhaustedModels.isEmpty {
                CollapsibleModelsButton(
                    title: language.exhaustedModelsToggleText(count: exhaustedModels.count, isExpanded: showsExhaustedModels),
                    isExpanded: showsExhaustedModels
                ) {
                    showsExhaustedModels.toggle()
                    notifyLayoutChange()
                }

                if showsExhaustedModels {
                    ModelsRows(
                        models: exhaustedModels,
                        language: language,
                        warningThreshold: warningThreshold,
                        samples: samples,
                        viewModel: viewModel
                    )
                }
            }

            if !fullQuotaModels.isEmpty {
                CollapsibleModelsButton(
                    title: language.fullQuotaModelsToggleText(count: fullQuotaModels.count, isExpanded: showsFullQuotaModels),
                    isExpanded: showsFullQuotaModels
                ) {
                    showsFullQuotaModels.toggle()
                    notifyLayoutChange()
                }

                if showsFullQuotaModels {
                    ModelsRows(
                        models: fullQuotaModels,
                        language: language,
                        warningThreshold: warningThreshold,
                        samples: samples,
                        viewModel: viewModel
                    )
                }
            }
            }
        }
        .onChange(of: CodexLocalUsageModel.shared.currentAccountID) { _, _ in
            accountCollapseOverrides = [:]
            notifyLayoutChange()
        }
    }

    @ViewBuilder
    private func providerHeader() -> some View {
        Button(action: onToggleCollapse) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 4) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 9)

                    ProviderLogoIcon(provider: data.provider, pointSize: 12)
                        .foregroundStyle(.secondary)

                    Text(data.provider.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    if data.provider != .codex,
                       let source = providerSourceSummary() {
                        Text(source)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Text(providerHeaderTrailing ?? "")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(language.providerCollapseHint(isCollapsed: isCollapsed))
    }

    @ViewBuilder
    private func accountHeader(_ group: AccountModelGroup, isCurrent: Bool) -> some View {
        if data.provider == .codex {
            Button {
                toggleAccountCollapsed(group)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: isAccountCollapsed(group, isCurrent: isCurrent)
                            ? "chevron.right" : "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 8)

                        Text(group.accountName ?? "Unknown account")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            // 放不下就省略，不缩字号：账号名一缩，同一区块里
                            // 各行字号就不一致了（远看像某个账号"特殊"）。
                            .truncationMode(.tail)

                        if let plan = accountPlanSummary(group.models) {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(plan)
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                // 套餐名是装饰，账号名才是身份 —— 宽度不够时先让套餐名让位。
                                .layoutPriority(-1)
                        }
                    }

                    Spacer()

                    // 图标 + 标签 + 时间 + 剩余量。四段都是原子的，宽度压力全部
                    // 由左侧账号名吸收 —— 截掉半个 "10/5 11:1" 或半个 "43%"
                    // 比账号名少几个字符糟糕得多。
                    accountTrailingSummary(group, isCurrent: isCurrent)
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // tooltip 挂在整个头部上，不挂在右侧那几段上：Button 内部的子视图
            // 拿不到 hover，挂在它上面等于白写。
            .help(accountTrailingHelp(group, isCurrent: isCurrent))
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(accountSourceSummary(group.models))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)

                Spacer()

                HStack(spacing: 4) {
                    Text(group.accountName ?? "Unknown account")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let plan = accountPlanSummary(group.models) {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(plan)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
        }
    }

    /// 账号下面的 cycle 切换。**只有一个 cycle 时不画** —— 一个只能选中的
    /// 按钮按下去什么也不会变，只是骗人；而且那种情况下（通常就是 Weekly）
    /// 头部已经直接显示它的数字了。
    ///
    /// 选择按账号记住，不是全局：两个账号想看的窗口经常不一样。
    @ViewBuilder
    private func accountCycleSwitcher(_ group: AccountModelGroup) -> some View {
        let cycles = selectableCycles(group)
        let selectedID = selectedCycleRow(group)?.id
        HStack(spacing: 6) {
            ForEach(cycles, id: \.id) { cycle in
                let isSelected = cycle.id == selectedID
                Button {
                    viewModel.setCycleChoice(
                        cycle.modelName, provider: data.provider, accountName: group.accountName)
                } label: {
                    Text(cycle.modelName)
                        .font(.system(size: 9, weight: isSelected ? .bold : .regular, design: .rounded))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(isSelected ? Color.primary.opacity(0.12) : Color.clear))
                        .overlay(
                            Capsule().strokeBorder(
                                Color.primary.opacity(isSelected ? 0.35 : 0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(isSelected
                    ? "头部正在显示这个 cycle 的剩余量"
                    : "点头部改看这个 cycle")
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }

    /// 账号头部右侧：状态图标 + 剩余量。
    ///
    /// 这里刻意**不写"Latest"或"Mix"这种字**。它们是为了让来源可见而造的词，
    /// 但读者要先理解这个词才知道它在说什么——为一个图标就能说清的事创造一个
    /// 术语，代价是每个看到它的人都要先查一遍。图标承载"来自哪里"，tooltip
    /// 解释"这是怎么回事"，行内只留真正每天都要读的那个数字。
    ///
    /// 本机账号仍然显示来源名（OAuth / Codex CLI），那不是造出来的词，是这台
    /// Mac 到底用哪种登录方式在跑，删了反而丢信息。
    ///
    /// 折叠时就把剩余量放在这里，是为了不用展开也能读到数字 —— 展开只留给
    /// "想看全部 cycle" 和 "想换一个 cycle 看" 这两件事。
    @ViewBuilder
    private func accountTrailingSummary(
        _ group: AccountModelGroup,
        isCurrent: Bool
    ) -> some View {
        let summary = accountTrailing(group, isCurrent: isCurrent)
        HStack(spacing: 3) {
            ForEach(summary.symbols, id: \.self) { symbol in
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            if !summary.symbols.isEmpty, !summary.sourceLabel.isEmpty {
                Text("·").foregroundStyle(.quaternary)
            }
            Text(summary.sourceLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            if let percent = summary.percent {
                if !summary.symbols.isEmpty || !summary.sourceLabel.isEmpty {
                    Text("·").foregroundStyle(.quaternary)
                }
                Text("\(percent)%")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(percentColor(percent))
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    /// 悬停头部时解释这个数字的来历。
    ///
    /// 一句话说完"来自哪里"和"什么时候量的"，再在多于一个来源时补一句为什么
    /// —— 一个账号同时有本机和云端数据时，显示的是其中较新的一次，这个取舍
    /// 不写出来就会让人以为数字对不上。
    private func accountTrailingHelp(
        _ group: AccountModelGroup, isCurrent: Bool
    ) -> String {
        let summary = accountTrailing(group, isCurrent: isCurrent)
        let kinds = AccountSourceKind.ordered(summary.kinds)
        let remote = kinds.filter { $0 != .local }
        let time = summary.sampledAt.map { language.updatedAgoText(from: $0) } ?? ""
        let lang = language

        var lines: [String] = []
        if kinds.contains(.local) {
            lines.append(lang.accountSourceLocalLine)
            if !remote.isEmpty {
                lines.append(lang.accountSourcePicksNewerLine)
            }
        }
        for kind in remote {
            switch kind {
            case .cloud: lines.append(lang.accountSourceCloudLine)
            case .watch: lines.append(lang.accountSourceWatchLine)
            case .local: break
            }
        }
        let body = lines.joined(separator: "\n")
        return time.isEmpty ? body : body + "\n" + time
    }

    private func percentColor(_ percent: Int) -> Color {
        switch percent {
        case ..<10: return .red
        case ..<25: return .orange
        default: return .secondary
        }
    }

    /// 折叠状态下这一行要显示的剩余量，取自**用户选中的那个 cycle**。
    ///
    /// 只有一个 cycle 时没得选，直接用它（通常就是 Weekly）；有两个时读用户
    /// 之前的选择，没有选择过就先落在"当前正在跑的那个窗口"上 —— 与其空着
    /// 让用户猜，不如给一个会随时间自己变对的初值，之后点一下就能换。
    private func selectedCycleRow(_ group: AccountModelGroup) -> ModelUsageData? {
        let rows = selectableCycles(group)
        guard !rows.isEmpty else { return group.models.first }
        if let stored = viewModel.cycleChoice(provider: data.provider, accountName: group.accountName),
           let hit = rows.first(where: { $0.modelName == stored }) {
            return hit
        }
        return rows.first(where: { isWindowRunningNow($0) }) ?? rows.first
    }

    /// 这个窗口此刻是不是正在跑。用来在用户还没选过 cycle 时给一个会自己变对的
    /// 初值 —— 过了重置点，Weekly 才是"正在跑"的那个，5h 已经不是了。
    private func isWindowRunningNow(_ model: ModelUsageData) -> Bool {
        let now = Date()
        if let start = model.startTime, let end = model.endTime {
            return start <= now && now <= end
        }
        if let end = model.endTime { return end > now }
        return true
    }

    /// 这个账号可以切换的 cycle 行。只有一个就没有"选择"这回事 —— 一个按钮
    /// 只有一个选项，按下去什么也不会变，只是骗人。
    private func selectableCycles(_ group: AccountModelGroup) -> [ModelUsageData] {
        group.models.count > 1 ? group.models : []
    }

    private struct AccountTrailing {
        let symbols: [String]
        /// 行内保留的来源名。只有本机时是 OAuth / Codex CLI / Local；
        /// 有远端来源时留空 —— 那时该说的是"来自哪儿"，已经由图标说明了，
        /// 再加一个词只会挤掉数字。
        let sourceLabel: String
        let kinds: Set<AccountSourceKind>
        let sampledAt: Date?
        let percent: Int?
    }

    private func accountTrailing(
        _ group: AccountModelGroup, isCurrent: Bool
    ) -> AccountTrailing {
        let kinds = group.models.reduce(into: Set<AccountSourceKind>()) {
            $0.formUnion($1.accountSourceKinds)
        }
        let remote = kinds.subtracting([.local])
        let symbols = AccountSourceKind.ordered(remote).compactMap(\.symbolName)
        let row = selectedCycleRow(group)
        let sourceLabel = kinds.isSubset(of: [.local])
            ? accountSourceSummary(group.models)
            : ""
        let sampledAt: Date? = isCurrent ? nil : row?.sampledAt ?? group.models.compactMap(\.sampledAt).max()
        return AccountTrailing(
            symbols: symbols,
            sourceLabel: sourceLabel,
            kinds: kinds,
            sampledAt: sampledAt,
            percent: row.map { Int($0.currentIntervalPercentageRemaining.rounded()) })
    }

    /// 旧的纯文本摘要，仅保留给"只有一行"的老布局使用。
    private func nonCurrentAccountTrailingSummary(
        _ group: AccountModelGroup,
        isCurrent: Bool
    ) -> String {
        let source = accountSourceSummary(group.models)
        guard !isCurrent else { return source }
        guard let updated = group.models.compactMap(\.sampledAt).max() else {
            return source
        }
        return source + " · " + shortClockText(from: updated)
    }

    private func accountCollapseKey(_ group: AccountModelGroup) -> String {
        group.accountName ?? "__unknown__"
    }

    private func isAccountCollapsed(_ group: AccountModelGroup, isCurrent: Bool) -> Bool {
        // 折叠语义只属于 Codex 的账号分组；其他供应商的分组始终展开。
        guard data.provider == .codex else { return false }
        return accountCollapseOverrides[accountCollapseKey(group)] ?? !isCurrent
    }

    private func toggleAccountCollapsed(_ group: AccountModelGroup) {
        let wasCollapsed = isAccountCollapsed(group, isCurrent: isCurrentAccountGroup(group))
        accountCollapseOverrides[accountCollapseKey(group)] = !wasCollapsed
        notifyLayoutChange()
    }

    private func isCurrentAccountGroup(_ group: AccountModelGroup) -> Bool {
        guard data.provider == .codex,
              let currentName = CodexLocalUsageModel.shared.currentAccountID
                  .flatMap({ CodexLocalUsageModel.shared.accountLabels[$0] }),
              let account = group.accountName else { return false }
        return currentName.caseInsensitiveCompare(account) == .orderedSame
    }

    /// providerHeader 右侧用的副标题（当前只对 MiniMax 显示套餐 + 到期日）。
    /// 返回 nil 时 caller 走默认 ready/total。
    private func providerHeaderSubtitle() -> String? {
        guard data.provider == .miniMax,
              let title = data.subscribeTitle, !title.isEmpty else {
            return nil
        }
        return language.miniMaxSubscribeSubtitle(
            title: title,
            endTime: data.subscribeEndTime
        )
    }

    /// 供应商标题右侧显示什么。
    ///
    /// 优先级：订阅信息 > 最后更新时间 + 当前账号的剩余额度 > 空。
    ///
    /// 这里原本是一个计数（`2/5` = 几个账号的数据还新鲜，`2/2` = 几个模型还有
    /// 余额）。两种含义不一样，却占着同一个位置，而且都是排障视角：前者回答
    /// "有几个旧了"，后者回答 "有几个没欠费"。日常没人问这两个问题，而它们
    /// 占的却是这一节最好的位置。
    private var providerHeaderTrailing: String? {
        if let subtitle = providerHeaderSubtitle() { return subtitle }

        var parts: [String] = []
        // 时间取全部账号里最新的那一次：任何一行新了都说明这一节是活的，
        // 而挑某一个账号的时间只代表它自己。
        if let newest = data.models.compactMap(\.sampledAt).max() {
            parts.append(shortClockText(from: newest))
        }
        // 额度只取当前账号，因为它就是菜单栏环在显示的那一个 —— 同一个 app
        // 两个地方给出不同数字，比少一个数字更糟。本机没登录 Codex（纯云端
        // + 关注）时不显示：没有"主"可依，随便挑一个会让人以为是被特意选过的。
        if let current = providerHeaderCurrentRow {
            parts.append("\(Int(current.currentIntervalPercentageRemaining.rounded()))%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 标题右侧的额度代表哪一行：当前账号那组的第一行。
    private var providerHeaderCurrentRow: ModelUsageData? {
        let usage = CodexLocalUsageModel.shared
        guard let currentName = usage.currentAccountID.flatMap({ usage.accountLabels[$0] })
        else { return nil }
        return data.models.first {
            ($0.accountName ?? "").caseInsensitiveCompare(currentName) == .orderedSame
        }
    }

    private func providerSourceSummary() -> String? {
        sourceSummary(for: data.models)
    }

    private func accountSourceSummary(_ models: [ModelUsageData]) -> String {
        sourceSummary(for: models) ?? "Local"
    }

    private func sourceSummary(for models: [ModelUsageData]) -> String? {
        let sources = Set(models.compactMap { $0.parsedDetail.source })
        if sources.contains("Mix") { return "Mix" }
        if sources.contains("OAuth") { return "OAuth" }
        if sources.contains("Codex CLI") { return "Codex CLI" }
        if sources.contains("OpenAI Web") { return "OpenAI Web" }
        // A watched account is not a local one. Without this it falls through to
        // the "Local" fallback below and the row claims to be this Mac's own
        // quota -- the exact opposite of what watching means.
        if sources.contains("Watch") { return "Watch" }
        if sources.contains("Cloud") { return "Cloud" }
        return nil
    }

    private func accountPlanSummary(_ models: [ModelUsageData]) -> String? {
        models.lazy
            .compactMap { $0.parsedDetail.plan }
            .first
    }

    private func sortedMenuModels(_ models: [ModelUsageData]) -> [ModelUsageData] {
        models.sorted { lhs, rhs in
            lhs.isOrderedBeforeInMenu(rhs)
        }
    }

    private func notifyLayoutChange() {
        DispatchQueue.main.async {
            onLayoutChange()
        }
    }

    /// 非当前账号的「最后更新时间」：当天只显示时刻，跨天补上日期。
    /// 非当前账号可能是几天前的快照，只有 "11:50" 读不出是哪天，
    /// 所以跨天必须落成 "9/28 11:50" 才有参考价值。
    private func shortClockText(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = Calendar.current.isDateInToday(date)
            ? "HH:mm"
            : "M/d HH:mm"
        return formatter.string(from: date)
    }
}

private struct CollapsibleModelsButton: View {
    let title: String
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)

                Text(title)
                    .font(.system(size: 10, weight: .medium))

                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}

private struct ModelsRows: View {
    let models: [ModelUsageData]
    let language: AppLanguage
    let warningThreshold: Double
    let samples: (ModelUsageData) -> [ModelQuotaSample]
    let viewModel: UsageViewModel

    var body: some View {
        ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
            ModelRow(
                model: model,
                language: language,
                warningThreshold: warningThreshold,
                samples: samples(model),
                rendersAreaChart: model.isShortCurrentInterval,
                viewModel: viewModel
            )

            if index < models.count - 1 {
                Spacer()
                    .frame(height: 1)
            }
        }
    }
}

private extension ModelUsageData {
    func isOrderedBeforeInMenu(_ other: ModelUsageData) -> Bool {
        let lhsAccount = menuSortAccountName
        let rhsAccount = other.menuSortAccountName
        if lhsAccount != rhsAccount {
            return lhsAccount < rhsAccount
        }

        let lhsIntervalPriority = menuModelPriority
        let rhsIntervalPriority = other.menuModelPriority
        if lhsIntervalPriority != rhsIntervalPriority {
            return lhsIntervalPriority < rhsIntervalPriority
        }

        let lhsReset = endTime ?? .distantFuture
        let rhsReset = other.endTime ?? .distantFuture
        if lhsReset != rhsReset {
            return lhsReset < rhsReset
        }

        return modelName.localizedStandardCompare(other.modelName) == .orderedAscending
    }

    private var menuSortAccountName: String {
        guard let accountName, !accountName.isEmpty else {
            return ""
        }
        return accountName.localizedLowercase
    }

    private var menuModelPriority: Int {
        let name = modelName.lowercased()
        if name == "5h" { return 0 }
        if name == "weekly" { return 1 }
        if name.contains("spark") && isShortCurrentInterval { return 2 }
        if name.contains("spark") && name.contains("weekly") { return 3 }
        if isShortCurrentInterval { return 4 }
        return 5
    }
}

private extension AppLanguage {
    func exhaustedModelsToggleText(count: Int, isExpanded: Bool) -> String {
        switch self {
        case .english:
            return isExpanded ? "Hide \(count) exhausted models" : "Show \(count) exhausted models"
        case .simplifiedChinese:
            return isExpanded ? "收起 \(count) 个已用完模型" : "展开 \(count) 个已用完模型"
        }
    }
}

private struct ModelRow: View {
    let model: ModelUsageData
    let language: AppLanguage
    let warningThreshold: Double
    let samples: [ModelQuotaSample]
    let rendersAreaChart: Bool
    let viewModel: UsageViewModel

    @State private var isHovered: Bool = false
    @State private var isFullQuotaExpanded: Bool = false
    /// 悬停历史 cycle 时的预览窗口：非 nil 则曲线图切换到该周期。
    @State private var previewWindow: (start: Date, end: Date)?

    var body: some View {
        Group {
            if model.isFullQuotaUnused
                && !isFullQuotaExpanded
                && !isPromotedWeeklyCurve
                && !showsSnapshotLayout {
                collapsedFullQuotaRow
            } else {
                expandedContent
            }
        }
        .padding(10)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isHovered = true
            case .ended:
                isHovered = false
            }
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !isCyclesOnly || model.isFullQuotaUnused {
                headerRow
            }

            if isCurrentWindow || showsSnapshotLayout {
                // 样本为空时不渲染 84pt 曲线图容器，落到下方紧凑胶囊条兜底。
                if rendersAreaChart && !chartSamples.isEmpty {
                    QuotaAreaChart(
                        model: model,
                        samples: chartSamples,
                        tint: chartTint,
                        warningThreshold: warningThreshold,
                        forecastLookbackIntervals:
                            viewModel.quotaForecastLookbackIntervals,
                        maximumForecastSampleGap:
                            QuotaConsumptionForecaster.maximumSampleGap(
                                refreshInterval: viewModel.refreshInterval),
                        language: language,
                        isHovered: isHovered,
                        windowOverride: previewWindow
                    )
                    .frame(height: 84)
                } else {
                    let dayLabels = weeklyFullDayLabelPercents()
                    let barHeight: CGFloat = 10
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.primary.opacity(0.22))
                                    .frame(height: 6)

                                if model.currentIntervalBarPercent > 0 {
                                    Capsule()
                                        .fill(tint)
                                        .frame(width: geo.size.width * model.currentIntervalBarPercent / 100, height: 6)
                                }

                                // 天分隔线（周窗口特有：按本地 0:00 对齐，常驻）
                                ForEach(Array(weeklyDayMarkerPercents().enumerated()), id: \.offset) { _, percent in
                                    Rectangle()
                                        .fill(Color.primary.opacity(0.20))
                                        .frame(width: 1, height: 8)
                                        .position(
                                            x: geo.size.width * percent / 100,
                                            y: barHeight / 2
                                        )
                                }

                                // 节奏指针：onTrack 不画（跟 codexbar 一致）
                                if let pace = model.currentIntervalPace,
                                   pace.stage != .onTrack,
                                   let pacePercent = model.currentIntervalPaceUsedPercent {
                                    PaceTipStripes(
                                        percent: pacePercent,
                                        width: geo.size.width,
                                        isAhead: pace.stage.isAhead)
                                }
                            }
                            .frame(width: geo.size.width, height: barHeight)
                            .contentShape(Rectangle())

                            // 完整自然日的 MM/dd 标签：居中于当天正午，hover 才显示
                            if isHovered {
                                ForEach(Array(dayLabels.enumerated()), id: \.offset) { _, dayLabel in
                                    Text(dayLabel.label)
                                        .font(.system(size: 7, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .position(
                                            x: geo.size.width * dayLabel.percent / 100,
                                            y: barHeight + 4
                                        )
                                }
                            }
                        }
                    }
                    .frame(height: dayLabels.isEmpty ? barHeight : barHeight + 8)
                }

                metadataRow
            } else if isCyclesOnly {
                metadataRow
            }

            // 跨周期 utilization 柱图放最底：与图表 + 文字行形成"当前 → 元信息 → 历史"三段式
            if !cycles.isEmpty {
                ModelUtilizationBarsView(
                    cycles: cycles,
                    currentCycle: currentUtilizationCycle,
                    cycleDuration: model.currentIntervalDuration,
                    tint: cycleTint,
                    isHovered: isHovered,
                    onHoverCycle: supportsCyclePreview ? { previewWindow = $0 } : nil
                )
            }
        }
    }

    /// 只有当前正在渲染曲线图的行，悬停 cycle 才有东西可预览。
    private var supportsCyclePreview: Bool {
        isCurrentWindow && rendersAreaChart
    }

    /// 曲线图样本：悬停历史 cycle 时取该窗口的历史样本，否则用当前窗口样本。
    private var chartSamples: [ModelQuotaSample] {
        if let previewWindow {
            return viewModel.samples(for: model, in: previewWindow)
        }
        return samples
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            if model.isFullQuotaUnused {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
            }

            if !isCyclesOnly {
                Text(model.modelName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }

            Spacer()

            if isCurrentWindow || showsSnapshotLayout {
                Text(model.currentIntervalRemainingText)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if model.isFullQuotaUnused {
                isFullQuotaExpanded = false
            }
        }
    }

    private var collapsedFullQuotaRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 10)

            Text(model.modelName)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)

            Spacer()

            Text(model.currentIntervalRemainingText)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isFullQuotaExpanded = true
        }
    }

    @ViewBuilder
    private var metadataRow: some View {
        if shouldShowMetadataRow {
            HStack(spacing: 4) {
                if let cycleInfoText {
                    Text(cycleInfoText)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if model.hasWeeklyLimit {
                    if model.isWeeklyUnlimited {
                        Text(language == .simplifiedChinese ? "周无限制" : "Weekly unlimited")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else if model.isWeeklyFull {
                        Text(language.weeklyUnusedText())
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else if let percent = model.weeklyRemainingPercent, model.weeklyTotal <= 0 {
                        Text("周 \(percent)%")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("周 \(model.weeklyRemaining)/\(model.weeklyTotal)")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }

                if let pace = paceForLabel {
                    if model.hasWeeklyLimit {
                        Text("·")
                            .foregroundStyle(.tertiary)
                    }

                    Text(language.paceLabel(stage: pace.stage, deltaPercent: pace.deltaPercent))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(paceLabelColor(pace: pace))
                }

                if let resetsText {
                    if model.hasWeeklyLimit || hasPace {
                        Text("·")
                            .foregroundStyle(.tertiary)
                    }

                    Text(resetsText)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var isCurrentWindow: Bool {
        if isCloudModel,
           let sampledAt = model.sampledAt,
           let interval = viewModel.cloudCurrentWindowVisibilityLimit.interval,
           Date().timeIntervalSince(sampledAt) > interval {
            return false
        }
        guard let startTime = model.startTime, let endTime = model.endTime else { return true }
        let now = Date()
        return startTime <= now && now <= endTime
    }

    /// 云端账号的过期快照仍按完整行渲染（行头 + 胶囊条 + 元数据），
    /// 不退化成「只剩周期行」；新旧程度由账号头的「Cloud · HH:mm」（跨天补日期）表达。
    private var showsSnapshotLayout: Bool {
        isCloudModel && !isCurrentWindow
    }

    private var isCyclesOnly: Bool {
        guard !isCurrentWindow, !cycles.isEmpty else { return false }
        return !showsSnapshotLayout
    }

    private var isPromotedWeeklyCurve: Bool {
        rendersAreaChart && !model.isShortCurrentInterval
    }

    private var resetsText: String? {
        // 优先 detailText 里的 "resets MM/dd HH:mm"(codex 完整日期+时间)
        if let rest = model.parsedDetail.rest,
           rest.hasPrefix("resets ") {
            return String(rest.dropFirst("resets ".count))
        }
        // 退化到 resetTimeText(其它 provider 仅在非短窗口下)
        guard !model.isShortCurrentInterval, model.endTime != nil else { return nil }
        return model.resetTimeText
    }

    /// 节奏信息：短周期只显示偏离，长周期常驻显示，避免 weekly 行中间空洞。
    private var paceForLabel: UsagePace? {
        guard let pace = model.currentIntervalPace else { return nil }
        guard !model.isShortCurrentInterval || pace.stage != .onTrack else { return nil }
        return pace
    }

    private var hasPace: Bool { paceForLabel != nil }

    private var shouldShowMetadataRow: Bool {
        cycleInfoText != nil || model.hasWeeklyLimit || hasPace || resetsText != nil
    }

    private var cycleInfoText: String? {
        guard !cycles.isEmpty else { return nil }
        let label: String
        if model.isShortCurrentInterval {
            label = language.modelUtilizationShortCycleLabel()
        } else if isMonthlyWindow {
            label = language.modelUtilizationMonthlyCycleLabel()
        } else {
            label = language.modelUtilizationLongCycleLabel()
        }
        return "\(label) · left"
    }

    /// Kimi 的月度总量窗口（"Total usage"）没有 windowMinutes/startTime，
    /// 会被 isShortCurrentInterval 归到长周期分支，需要单独识别成月度。
    private var isMonthlyWindow: Bool {
        model.provider == .kimi && model.modelName == "Total usage"
    }

    private var currentUtilizationCycle: CurrentUtilizationCycle? {
        guard isCurrentWindow,
              let startTime = model.startTime,
              let endTime = model.endTime else {
            return nil
        }
        return CurrentUtilizationCycle(
            start: startTime,
            end: endTime,
            leftPercent: model.currentIntervalPercentageRemaining
        )
    }

    /// 跨周期 utilization 柱图数据：短周期 30 个 ≈ 6 天，周长周期 12 个 ≈ 3 个月。
    private var cycles: [(resetsAt: Date, peakPercent: Double)] {
        let limit = model.isShortCurrentInterval ? 30 : 12
        let cycles = viewModel.utilizationCycles(for: model, limit: limit)
        guard isCloudModel else { return cycles }
        let visibilityLimit = model.isShortCurrentInterval
            ? viewModel.cloudShortCyclesVisibilityLimit
            : viewModel.cloudWeeklyCyclesVisibilityLimit
        guard let interval = visibilityLimit.interval else { return cycles }
        let now = Date()
        return cycles.filter { cycle in
            now.timeIntervalSince(cycle.resetsAt) <= interval
        }
    }

    private var isCloudModel: Bool {
        model.parsedDetail.source == "Cloud"
    }

    private var tint: Color {
        tint(usedPercent: model.currentIntervalPercentageUsed,
             remainingPercent: model.currentIntervalPercentageRemaining)
    }

    private func tint(usedPercent: Double, remainingPercent: Double) -> Color {
        // 反向语义（credits）：使用中性的 secondary 颜色，避免被"已用%==100"的规则染红
        if model.progressBarPercentOverride != nil {
            return .secondary
        }
        if usedPercent >= 100 { return .red }
        if usedPercent >= 80 { return .orange }
        if usedPercent > 0 && remainingPercent <= warningThreshold { return .orange }
        if usedPercent > 0 { return .green }
        return .secondary
    }

    /// 曲线图 tint：悬停预览历史 cycle 时，用该周期自己的 peak used% 判定告警色，
    /// 避免当前周期低额度的 warning 色泄漏到历史周期预览。
    private var chartTint: Color {
        guard let previewWindow else { return tint }
        // 悬停的是当前 cycle：仍用实时剩余判定
        if let current = currentUtilizationCycle,
           abs(previewWindow.end.timeIntervalSince(current.end))
               <= ModelUtilizationHistory.resetBoundaryMergeTolerance {
            return tint
        }
        guard let cycle = cycles.first(where: {
            abs($0.resetsAt.timeIntervalSince(previewWindow.end))
                <= ModelUtilizationHistory.resetBoundaryMergeTolerance
        }) else { return cycleTint }
        return tint(usedPercent: cycle.peakPercent,
                    remainingPercent: 100 - cycle.peakPercent)
    }

    private var cycleTint: Color {
        model.progressBarPercentOverride == nil ? .green : .secondary
    }

    /// 周窗口才画天分隔线：按本地 0:00 对齐（与曲线图日界线一致）
    private func weeklyDayMarkerPercents() -> [Double] {
        guard !model.isShortCurrentInterval else { return [] }
        guard let window = model.quotaChartWindow() else { return [] }
        return QuotaChartTimeTickBuilder.midnightTicks(startTime: window.start, endTime: window.end)
            .map { $0.ratio * 100 }
    }

    /// 周窗口内完整自然日的 MM/dd 标签位置（居中于当天正午），hover 时显示。
    /// 月计划这类长窗口全量日标签会挤在一起，抽稀到最多 6 个。
    private func weeklyFullDayLabelPercents() -> [(percent: Double, label: String)] {
        guard !model.isShortCurrentInterval else { return [] }
        guard let window = model.quotaChartWindow() else { return [] }
        var ticks = QuotaChartTimeTickBuilder.fullDayTicks(startTime: window.start, endTime: window.end)
        let maxLabels = 6
        if ticks.count > maxLabels {
            let step = Int(ceil(Double(ticks.count) / Double(maxLabels)))
            ticks = ticks.enumerated().compactMap { index, tick in
                index % step == 0 ? tick : nil
            }
        }
        return ticks.map { (percent: $0.ratio * 100, label: $0.label) }
    }

    /// reset time 行里 pace 文字颜色：reserve（你有余量）用 secondary 灰，
    /// deficit（你快用完）用红色提醒
    private func paceLabelColor(pace: UsagePace) -> Color {
        if pace.stage == .onTrack {
            let roundedDelta = Int(abs(pace.deltaPercent).rounded())
            return roundedDelta > 0 && pace.deltaPercent > 0 ? .red : .secondary
        }

        switch pace.stage {
        case .onTrack, .slightlyBehind, .behind, .farBehind:
            return .secondary
        case .slightlyAhead, .ahead, .farAhead:
            return .red
        }
    }
}

/// 节奏指针：3 段式条纹 marker，参考 codexbar 的 UsageProgressBar.pace tip
private struct PaceTipStripes: View {
    let percent: Double
    let width: CGFloat
    let isAhead: Bool

    private let stripeWidth: CGFloat = 2
    private let stripeGap: CGFloat = 1
    private let totalHeight: CGFloat = 10

    var body: some View {
        let x = width * percent / 100
        let color: Color = isAhead ? .green : .red

        HStack(spacing: stripeGap) {
            Rectangle()
                .fill(color.opacity(0.30))
                .frame(width: stripeWidth, height: totalHeight)
            Rectangle()
                .fill(color)
                .frame(width: stripeWidth, height: totalHeight)
        }
        .frame(width: stripeWidth * 2 + stripeGap, height: totalHeight)
        .position(x: x, y: totalHeight / 2)
    }
}

private struct QuotaAreaChart: View {
    let model: ModelUsageData
    let samples: [ModelQuotaSample]
    let tint: Color
    let warningThreshold: Double
    let forecastLookbackIntervals: Int
    let maximumForecastSampleGap: TimeInterval
    let language: AppLanguage
    let isHovered: Bool
    /// 历史 cycle 悬停预览：非 nil 时 x 轴/刻度/坐标定位改用该窗口，
    /// 并跳过 pace 参考线与消耗预测（都是"当前周期"概念）。
    var windowOverride: (start: Date, end: Date)?

    @State private var hoverLocation: CGPoint?

    private var windowStart: Date? { windowOverride?.start ?? model.quotaChartWindow()?.start }
    private var windowEnd: Date? { windowOverride?.end ?? model.quotaChartWindow()?.end }

    /// Y 轴上限：预览历史 count 窗口时，旧周期总量可能与当前不同，
    /// 用窗口内样本最大值兜底防截断；percent 模式恒 100。
    private var yAxisMax: Double {
        let base = model.currentIntervalYAxisMax
        guard windowOverride != nil, !model.isCurrentIntervalPercentMode else { return base }
        let maxRemaining = samples.map { Double($0.remaining) }.max() ?? 0
        return max(base, maxRemaining)
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = QuotaChartLayout(size: geometry.size)

            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawBackground(context: &context, layout: layout)
                    drawAxes(context: &context, layout: layout)
                    drawTimeTicks(context: &context, layout: layout)
                    drawPaceGuide(context: &context, layout: layout)
                    drawForecasts(context: &context, layout: layout)
                    drawSeries(context: &context, layout: layout)
                    drawHoveredGuide(context: &context, layout: layout)
                }

                if let hoveredSample = hoveredSample(in: layout) {
                    ChartCallout(text: hoverText(for: hoveredSample))
                        .position(calloutPosition(for: hoveredSample, layout: layout))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverLocation = location
                case .ended:
                    hoverLocation = nil
                }
            }
        }
    }

    private func drawBackground(context: inout GraphicsContext, layout: QuotaChartLayout) {
        let rect = RoundedRectangle(cornerRadius: 7, style: .continuous).path(in: layout.plotRect)
        context.fill(rect, with: .color(Color.primary.opacity(0.035)))
    }

    private func drawAxes(context: inout GraphicsContext, layout: QuotaChartLayout) {
        var axisPath = Path()
        axisPath.move(to: CGPoint(x: layout.plotRect.minX, y: layout.plotRect.minY))
        axisPath.addLine(to: CGPoint(x: layout.plotRect.minX, y: layout.plotRect.maxY))
        axisPath.addLine(to: CGPoint(x: layout.plotRect.maxX, y: layout.plotRect.maxY))
        context.stroke(axisPath, with: .color(Color.primary.opacity(0.14)), lineWidth: 1)

        let yAxisMax = yAxisMax
        if yAxisMax > 0, warningThreshold > 0, warningThreshold < 100 {
            let thresholdY = yPosition(forRemaining: yAxisMax * warningThreshold / 100, layout: layout)
            var thresholdPath = Path()
            thresholdPath.move(to: CGPoint(x: layout.plotRect.minX, y: thresholdY))
            thresholdPath.addLine(to: CGPoint(x: layout.plotRect.maxX, y: thresholdY))
            context.stroke(
                thresholdPath,
                with: .color(Color.orange.opacity(0.45)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            if isHovered {
                // label 夹在 plotRect 上下边内，避免被裁
                let labelHeight: CGFloat = 12
                let minLabelTopY = layout.plotRect.minY
                let maxLabelTopY = layout.plotRect.maxY - labelHeight
                let labelTopY = min(max(thresholdY - 1, minLabelTopY), maxLabelTopY)
                context.draw(
                    axisLabel("\(Int(warningThreshold))%"),
                    at: CGPoint(x: layout.plotRect.minX + 2, y: labelTopY),
                    anchor: .topLeading)
            }
        }

        let topLabel = model.isCurrentIntervalPercentMode
            ? axisLabel("100%")
            : axisLabel("\(Int(yAxisMax))")
        context.draw(topLabel, at: CGPoint(x: layout.leftAxisLabelX, y: layout.plotRect.minY), anchor: .leading)
        context.draw(axisLabel("0"), at: CGPoint(x: layout.leftAxisLabelX, y: layout.plotRect.maxY), anchor: .leading)

        if let startTime = windowStart, let endTime = windowEnd {
            context.draw(axisLabel(axisTimeText(for: startTime)), at: CGPoint(x: layout.plotRect.minX, y: layout.axisLabelY), anchor: .topLeading)
            context.draw(axisLabel(axisTimeText(for: endTime)), at: CGPoint(x: layout.plotRect.maxX, y: layout.axisLabelY), anchor: .topTrailing)
        }
    }

    /// Short curves use natural-hour divisions; multi-day curves use local-midnight
    /// divisions. Grid lines remain visible; labels appear on hover, centered on
    /// each fully-contained segment — `3PM`-style labels on hour midpoints for
    /// short curves, MM/dd labels on day midpoints for multi-day curves.
    private func drawTimeTicks(context: inout GraphicsContext, layout: QuotaChartLayout) {
        let ticks = QuotaChartTimeTickBuilder.ticks(
            startTime: windowStart,
            endTime: windowEnd)
        guard !ticks.isEmpty else { return }

        for tick in ticks {
            let x = layout.plotRect.minX + layout.plotRect.width * tick.ratio
            var path = Path()
            path.move(to: CGPoint(x: x, y: layout.plotRect.minY))
            path.addLine(to: CGPoint(x: x, y: layout.plotRect.maxY))
            context.stroke(
                path,
                with: .color(Color.primary.opacity(0.10)),
                style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }

        // hover 标签：只有完整落在窗口内的时段（自然小时/自然日）才显示，
        // 居中于该时段中间点
        if isHovered, let windowStart, let windowEnd {
            let isMultiDay = windowEnd.timeIntervalSince(windowStart) > 24 * 3_600
            let labelTicks = isMultiDay
                ? QuotaChartTimeTickBuilder.fullDayTicks(startTime: windowStart, endTime: windowEnd)
                : QuotaChartTimeTickBuilder.fullHourTicks(startTime: windowStart, endTime: windowEnd)
            for tick in labelTicks {
                let x = layout.plotRect.minX + layout.plotRect.width * tick.ratio
                context.draw(
                    segmentTickLabel(tick.label),
                    at: CGPoint(x: x, y: layout.axisLabelY - 11),
                    anchor: .center)
            }
        }
    }

    /// 匀速消耗参考线：从周期起点的 100% 连接到周期终点的 0%。
    /// 它是常驻基准线；近期消耗预测会在其后单独叠加绘制。
    private func drawPaceGuide(
        context: inout GraphicsContext,
        layout: QuotaChartLayout
    ) {
        guard windowOverride == nil else { return }
        guard let pace = model.currentIntervalPace else { return }

        let color: Color = pace.stage.isAhead ? .green : .red

        var path = Path()
        path.move(to: CGPoint(x: layout.plotRect.minX, y: layout.plotRect.minY))
        path.addLine(to: CGPoint(x: layout.plotRect.maxX, y: layout.plotRect.maxY))
        context.stroke(
            path,
            with: .color(color.opacity(0.55)),
            style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }

    private func drawSeries(context: inout GraphicsContext, layout: QuotaChartLayout) {
        let points = plottedSamples(in: layout)
        guard !points.isEmpty else { return }

        if points.count == 1, let point = points.first {
            var areaPath = Path()
            areaPath.move(to: CGPoint(x: layout.plotRect.minX, y: layout.plotRect.maxY))
            areaPath.addLine(to: CGPoint(x: layout.plotRect.minX, y: point.y))
            areaPath.addLine(to: CGPoint(x: point.x, y: point.y))
            areaPath.addLine(to: CGPoint(x: point.x, y: layout.plotRect.maxY))
            areaPath.closeSubpath()
            // A rolling GLM window has no evidence before its first observation.
            if !(model.isGLMFiveHourWindow && model.startTime == nil) {
                context.fill(
                    areaPath,
                    with: .linearGradient(
                        Gradient(colors: [
                            tint.opacity(0.22),
                            tint.opacity(0.03)
                        ]),
                        startPoint: CGPoint(x: 0, y: layout.plotRect.minY),
                        endPoint: CGPoint(x: 0, y: layout.plotRect.maxY)
                    )
                )
            }

            var guide = Path()
            guide.move(to: CGPoint(x: point.x, y: layout.plotRect.maxY))
            guide.addLine(to: point)
            context.stroke(guide, with: .color(tint.opacity(0.45)), lineWidth: 2)

            let markerRect = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
            context.fill(Path(ellipseIn: markerRect), with: .color(tint))
            return
        }

        guard let firstPoint = points.first,
              let lastPoint = points.last else { return }

        var areaPath = Path()
        areaPath.move(to: CGPoint(x: firstPoint.x, y: layout.plotRect.maxY))  // Y1=0
        areaPath.addLine(to: CGPoint(x: firstPoint.x, y: firstPoint.y))       // 到第一个点
        areaPath.addLines(points)                                              // 沿曲线到最后一个点
        areaPath.addLine(to: CGPoint(x: lastPoint.x, y: layout.plotRect.maxY)) // Yn=0
        areaPath.addLine(to: CGPoint(x: firstPoint.x, y: layout.plotRect.maxY)) // 回到 Y1=0
        areaPath.closeSubpath()
        context.fill(
            areaPath,
            with: .linearGradient(
                Gradient(colors: [
                    tint.opacity(0.22),
                    tint.opacity(0.03)
                ]),
                startPoint: CGPoint(x: 0, y: layout.plotRect.minY),
                endPoint: CGPoint(x: 0, y: layout.plotRect.maxY)
            )
        )

        var linePath = Path()
        linePath.addLines(points)
        context.stroke(
            linePath,
            with: .color(tint),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        )

        for point in points {
            let markerRect = CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)
            context.fill(Path(ellipseIn: markerRect), with: .color(tint))
        }
    }

    private func drawForecasts(
        context: inout GraphicsContext,
        layout: QuotaChartLayout
    ) {
        guard windowOverride == nil, let windowEnd = model.endTime else { return }
        let forecasts = QuotaConsumptionForecaster.forecasts(
            samples: samples,
            isPercentMode: model.isCurrentIntervalPercentMode,
            maximumLookbackIntervals: forecastLookbackIntervals,
            maximumSampleGap: maximumForecastSampleGap)

        for (index, forecast) in forecasts.enumerated() {
            let endDate = min(forecast.exhaustsAt, windowEnd)
            guard endDate > forecast.startsAt else { continue }
            let remainingAtEnd = max(
                0,
                forecast.startingRemaining
                    - forecast.consumptionPerSecond
                    * endDate.timeIntervalSince(forecast.startsAt))
            let opacities = [0.62, 0.44, 0.31, 0.22, 0.15]
            let opacity = opacities[min(index, opacities.count - 1)]

            var path = Path()
            path.move(to: CGPoint(
                x: xPosition(for: forecast.startsAt, layout: layout),
                y: yPosition(
                    forRemaining: forecast.startingRemaining,
                    layout: layout)))
            path.addLine(to: CGPoint(
                x: xPosition(for: endDate, layout: layout),
                y: yPosition(forRemaining: remainingAtEnd, layout: layout)))
            context.stroke(
                path,
                with: .color(tint.opacity(opacity)),
                style: StrokeStyle(
                    lineWidth: 1,
                    lineCap: .round,
                    dash: [5, 4]))
        }
    }

    /// 当前这个 cycle 是不是已经烧超前了（deficit）。
    ///
    /// 只看 stage：ahead 三档才是"用得比匀速快"，也就是提前透支。onTrack
    /// 不算 —— 还在节奏内，画一条参考线只会让人以为出事了。
    private var isInDeficit: Bool {
        guard let stage = model.currentIntervalPace?.stage else { return false }
        switch stage {
        case .slightlyAhead, .ahead, .farAhead: return true
        case .onTrack, .slightlyBehind, .behind, .farBehind: return false
        }
    }

    private func drawHoveredGuide(context: inout GraphicsContext, layout: QuotaChartLayout) {
        guard let hoveredSample = hoveredSample(in: layout) else { return }

        let point = plottedPoint(for: hoveredSample, layout: layout)

        var guide = Path()
        guide.move(to: CGPoint(x: point.x, y: layout.plotRect.minY))
        guide.addLine(to: CGPoint(x: point.x, y: layout.plotRect.maxY))
        context.stroke(guide, with: .color(tint.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

        // 超额时补一条水平参考线：从当前点一路拉到右边界。
        //
        // 它和那条斜向的匀速虚线是一对 —— 斜线说"按匀速你本该在这儿"，横线说
        // "你现在实际在这儿"，两条线之间的横向距离就是提前透支掉的时间窗。
        // 只画斜线的话，那个交叉点要靠眼睛在图上比；画了横线，交叉位置直接
        // 落在实线上，一眼能读出"我提前用了多少"。
        //
        // 用 tint 而不是写死绿色：这条线属于预测线那一族，用同族的颜色才不会
        // 被当成数据；而曲线本身在重度超额时会变成橙色/红色，这时候一根绿线
        // 反而和它对不上。用 stage 判定而不是 deltaPercent 的正负 —— 这两个
        // 符号约定在代码里是相反的（见 AppLanguage.paceLabel 与
        // currentIntervalPaceDeltaPercent），看 stage 不会踩错。
        if isInDeficit {
            var reference = Path()
            reference.move(to: CGPoint(x: point.x, y: point.y))
            reference.addLine(to: CGPoint(x: layout.plotRect.maxX, y: point.y))
            context.stroke(
                reference,
                with: .color(tint.opacity(0.55)),
                style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [5, 4]))
        }

        let markerRect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
        context.fill(Path(ellipseIn: markerRect), with: .color(.white))
        context.stroke(Path(ellipseIn: markerRect), with: .color(tint), lineWidth: 2)
    }

    private func plottedSamples(in layout: QuotaChartLayout) -> [CGPoint] {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        let effective: [ModelQuotaSample]
        if model.isCurrentIntervalPercentMode {
            let withPercent = sorted.filter { $0.percent != nil }
            effective = withPercent.isEmpty && !sorted.isEmpty ? [sorted.last!] : withPercent
        } else {
            effective = sorted
        }
        return effective.map { plottedPoint(for: $0, layout: layout) }
    }

    private func plottedPoint(for sample: ModelQuotaSample, layout: QuotaChartLayout) -> CGPoint {
        let yValue: Double
        if model.isCurrentIntervalPercentMode {
            yValue = Double(sample.percent ?? model.currentIntervalRemainingPercent ?? 0)
        } else {
            yValue = Double(sample.remaining)
        }
        return CGPoint(
            x: xPosition(for: sample.timestamp, layout: layout),
            y: yPosition(forRemaining: yValue, layout: layout)
        )
    }

    private func xPosition(for date: Date, layout: QuotaChartLayout) -> CGFloat {
        guard let startTime = windowStart, let endTime = windowEnd else {
            return layout.plotRect.minX
        }

        let totalDuration = max(endTime.timeIntervalSince(startTime), 1)
        let elapsed = min(max(date.timeIntervalSince(startTime), 0), totalDuration)
        let ratio = elapsed / totalDuration
        return layout.plotRect.minX + layout.plotRect.width * ratio
    }

    private func yPosition(forRemaining remaining: Double, layout: QuotaChartLayout) -> CGFloat {
        let yAxisMax = yAxisMax
        guard yAxisMax > 0 else { return layout.plotRect.maxY }
        let clampedRemaining = min(max(remaining, 0), yAxisMax)
        let ratio = clampedRemaining / yAxisMax
        return layout.plotRect.maxY - layout.plotRect.height * ratio
    }

    private func hoveredSample(in layout: QuotaChartLayout) -> ModelQuotaSample? {
        guard let hoverLocation,
              layout.plotRect.insetBy(dx: -8, dy: -8).contains(hoverLocation),
              !samples.isEmpty else {
            return nil
        }

        return samples.min { lhs, rhs in
            abs(xPosition(for: lhs.timestamp, layout: layout) - hoverLocation.x) <
                abs(xPosition(for: rhs.timestamp, layout: layout) - hoverLocation.x)
        }
    }

    private func hoverText(for sample: ModelQuotaSample) -> String {
        let value: String
        if model.isCurrentIntervalPercentMode {
            value = "\(sample.percent ?? model.currentIntervalRemainingPercent ?? 0)%"
        } else {
            value = "\(sample.remaining)"
        }
        return "\(tooltipTimeText(for: sample.timestamp)) · \(value)"
    }

    private func calloutPosition(for sample: ModelQuotaSample, layout: QuotaChartLayout) -> CGPoint {
        let point = plottedPoint(for: sample, layout: layout)
        let tooltipWidth: CGFloat = 120
        let x = min(max(point.x, tooltipWidth / 2), layout.size.width - tooltipWidth / 2)
        let y = max(point.y - 18, 12)
        return CGPoint(x: x, y: y)
    }

    private func axisLabel(_ text: String) -> Text {
        Text(text)
            .font(.system(size: 9, design: .rounded))
            .foregroundStyle(.secondary)
    }

    /// 完整时段（自然小时/自然日）的 hover 标签：比轴标签更小，避免喧宾夺主。
    private func segmentTickLabel(_ text: String) -> Text {
        Text(text)
            .font(.system(size: 7, design: .rounded))
            .foregroundStyle(.secondary)
    }

    private func axisTimeText(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = .current
        formatter.locale = .current

        if let startTime = model.startTime,
           Calendar.current.isDate(date, inSameDayAs: startTime) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "MM/dd HH:mm"
        }

        return formatter.string(from: date)
    }

    private func tooltipTimeText(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = .current
        formatter.locale = .current

        // 短重置窗口（≤ 24h）起止通常在同一天，省掉日期避免 callout 显得过宽；
        // 分钟级精度对 hover 已经够用，秒级噪声反而干扰阅读。
        if let startTime = model.startTime,
           Calendar.current.isDate(date, inSameDayAs: startTime) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "MM/dd HH:mm"
        }

        return formatter.string(from: date)
    }
}

private struct QuotaChartLayout {
    let size: CGSize

    private let leftInset: CGFloat = 30
    private let rightInset: CGFloat = 8
    private let topInset: CGFloat = 8
    private let bottomInset: CGFloat = 18

    var plotRect: CGRect {
        CGRect(
            x: leftInset,
            y: topInset,
            width: max(size.width - leftInset - rightInset, 1),
            height: max(size.height - topInset - bottomInset, 1)
        )
    }

    var leftAxisLabelX: CGFloat {
        3
    }

    var axisLabelY: CGFloat {
        plotRect.maxY + 4
    }
}

private struct ChartCallout: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}
