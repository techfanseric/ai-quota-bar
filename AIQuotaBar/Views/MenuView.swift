import AppKit
import CodexBarCore
import SwiftUI

struct MenuView: View {
    @Bindable var viewModel: UsageViewModel
    var onOpenSettings: () -> Void
    var onLayoutChange: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                modelsList
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: maxScrollableHeight)

            Divider()
                .padding(.vertical, 4)
            footer
        }
        .padding(10)
        .frame(width: 296)
    }

    private var maxScrollableHeight: CGFloat {
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 600
        let menuChromeHeight: CGFloat = 56
        return max(540, visibleHeight * 0.9 - menuChromeHeight)
    }

    private var language: AppLanguage {
        viewModel.appLanguage
    }

    @ViewBuilder
    private var modelsList: some View {
        let sections = viewModel.providerUsageSections
        if !sections.isEmpty {
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

                if let cloudError = viewModel.cloudUsageLoadError {
                    HStack(spacing: 6) {
                        Image(systemName: "icloud.slash")
                            .font(.system(size: 10, weight: .medium))
                        Text("Cloud data unavailable: \(cloudError)")
                            .font(.system(size: 10))
                            .lineLimit(2)
                        Spacer()
                    }
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                }

                ForEach(Array(sections.enumerated()), id: \.offset) { _, data in
                    if data.provider == .codex && data.models.isEmpty {
                        MenuPlaceholderCard(
                            icon: "terminal.fill",
                            title: language.codexMenuNotConfiguredTitle(),
                            message: language.codexMenuNotConfiguredMessage(),
                            primaryActionTitle: language.text(.settings),
                            primaryAction: onOpenSettings
                        )
                    } else {
                        ProviderModelsSection(
                            data: data,
                            language: language,
                            warningThreshold: viewModel.effectiveWarningThreshold,
                            samples: viewModel.samples(for:),
                            viewModel: viewModel,
                            onLayoutChange: onLayoutChange
                        )
                    }
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
        } else if shouldShowCodexEmptyState {
            MenuPlaceholderCard(
                icon: "terminal.fill",
                title: language.codexMenuNotConfiguredTitle(),
                message: language.codexMenuNotConfiguredMessage(),
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

            Spacer()

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
    let onLayoutChange: () -> Void

    @State private var showsFullQuotaModels = false
    @State private var showsExhaustedModels = false

    private var visibleModels: [ModelUsageData] {
        return sortedMenuModels(data.models).filter {
            isVisibleInlineModel($0)
        }
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
        if !hasRenderableCurrentWindow(for: model) {
            return true
        }
        return !model.isExhaustedCurrentInterval && !model.isFullQuotaUnused
    }

    private func hasVisibleContent(for model: ModelUsageData) -> Bool {
        hasRenderableCurrentWindow(for: model) || !utilizationCycles(for: model).isEmpty
    }

    private func hasRenderableCurrentWindow(for model: ModelUsageData) -> Bool {
        if model.parsedDetail.source == "Cloud",
           let sampledAt = model.sampledAt,
           Date().timeIntervalSince(sampledAt) > 3600 {
            return false
        }
        guard let startTime = model.startTime, let endTime = model.endTime else { return true }
        let now = Date()
        return startTime <= now && now <= endTime
    }

    private func utilizationCycles(for model: ModelUsageData) -> [(resetsAt: Date, peakPercent: Double)] {
        let limit = model.isShortCurrentInterval ? 30 : 12
        return viewModel.utilizationCycles(for: model, limit: limit)
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
        let groups = groupedVisibleModels
        VStack(alignment: .leading, spacing: 0) {
            providerHeader()

            ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, group in
                let rows = group.models
                accountHeader(group)

                ForEach(Array(rows.enumerated()), id: \.element.id) { index, model in
                    ModelRow(
                        model: model,
                        language: language,
                        warningThreshold: warningThreshold,
                        samples: samples(model),
                        viewModel: viewModel
                    )

                    if !(index == rows.count - 1 && groupIndex == groups.count - 1) {
                        Spacer()
                            .frame(height: 1)
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

    @ViewBuilder
    private func providerHeader() -> some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 4) {
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

            Text(providerHeaderSubtitle() ?? providerCountSummary())
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func accountHeader(_ group: AccountModelGroup) -> some View {
        if data.provider == .codex || group.accountName != nil {
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

    private func providerCountSummary() -> String {
        guard data.provider == .codex else {
            return language.menuBarCompactText(ready: data.readyModelsCount, total: data.modelCount)
        }

        let accountGroups = Dictionary(grouping: data.models) { model in
            model.normalizedAccountName
        }
        .filter { !$0.key.isEmpty }

        let activeAccounts = accountGroups.values.filter { models in
            models.contains { model in
                let source = model.parsedDetail.source ?? ""
                if source != "Cloud" {
                    return true
                }
                guard let sampledAt = model.sampledAt else { return false }
                return Date().timeIntervalSince(sampledAt) <= 3600
            }
        }.count

        return "\(activeAccounts)/\(accountGroups.count)"
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

    private func shortClockText(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
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
    let viewModel: UsageViewModel

    @State private var isHovered: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !isCyclesOnly {
                HStack(spacing: 8) {
                    Text(model.modelName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)

                    Spacer()

                    if isCurrentWindow {
                        Text(model.currentIntervalRemainingText)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(tint)
                    }
                }
            }

            if isCurrentWindow {
                if model.isShortCurrentInterval {
                    QuotaAreaChart(
                        model: model,
                        samples: samples,
                        tint: tint,
                        warningThreshold: warningThreshold,
                        language: language,
                        isHovered: isHovered
                    )
                    .frame(height: 84)
                } else {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.primary.opacity(0.22))
                                .frame(height: 6)

                            if model.currentIntervalBarPercent > 0 {
                                Capsule()
                                    .fill(tint)
                                    .frame(width: geo.size.width * model.currentIntervalBarPercent / 100, height: 6)
                            }

                            // 天分隔线（周窗口特有：6 道线，按 7 天等分，常驻）
                            ForEach(Array(weeklyDayMarkerPercents().enumerated()), id: \.offset) { _, percent in
                                Rectangle()
                                    .fill(Color.primary.opacity(0.20))
                                    .frame(width: 1, height: 8)
                                    .position(
                                        x: geo.size.width * percent / 100,
                                        y: geo.size.height / 2
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
                        .contentShape(Rectangle())
                    }
                    .frame(height: 10)
                }

                HStack(spacing: 4) {
                    // 左侧:xx left / x/y 这种"还剩多少"的最直接信息
                    Text(model.currentIntervalBarRightText)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.secondary)

                    Spacer()

                    // 右侧:周信息 · 节奏偏差 · reset 时间(resets 放最右)
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
                        // · 在 weekly 和 pace 之间(weekly 存在时)
                        if model.hasWeeklyLimit {
                            Text("·")
                                .foregroundStyle(.tertiary)
                        }

                        Text(language.paceLabel(stage: pace.stage, deltaPercent: pace.deltaPercent))
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(paceLabelColor(paceStage: pace.stage))
                    }

                    if let resetsText {
                        // · 在 pace 和 resets 之间(左侧有 weekly 或 pace 时)
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

            // 跨周期 utilization 柱图放最底：与图表 + 文字行形成"当前 → 元信息 → 历史"三段式
            if !cycles.isEmpty {
                ModelUtilizationBarsView(
                    cycles: cycles,
                    cycleLabel: model.isShortCurrentInterval
                        ? language.modelUtilizationShortCycleLabel()
                        : language.modelUtilizationLongCycleLabel(),
                    cycleDuration: model.currentIntervalDuration,
                    tint: tint,
                    isHovered: isHovered
                )
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

    private var isCurrentWindow: Bool {
        if model.parsedDetail.source == "Cloud",
           let sampledAt = model.sampledAt,
           Date().timeIntervalSince(sampledAt) > 3600 {
            return false
        }
        guard let startTime = model.startTime, let endTime = model.endTime else { return true }
        let now = Date()
        return startTime <= now && now <= endTime
    }

    private var isCyclesOnly: Bool {
        !isCurrentWindow && !cycles.isEmpty
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

    /// 节奏信息:onTrack / 无数据时为 nil。
    private var paceForLabel: UsagePace? {
        guard let pace = model.currentIntervalPace, pace.stage != .onTrack else { return nil }
        return pace
    }

    private var hasPace: Bool { paceForLabel != nil }

    /// 跨周期 utilization 柱图数据：短周期 30 个 ≈ 6 天，周长周期 12 个 ≈ 3 个月。
    private var cycles: [(resetsAt: Date, peakPercent: Double)] {
        let limit = model.isShortCurrentInterval ? 30 : 12
        return viewModel.utilizationCycles(for: model, limit: limit)
    }

    private var tint: Color {
        // 反向语义（credits）：使用中性的 secondary 颜色，避免被"已用%==100"的规则染红
        if model.progressBarPercentOverride != nil {
            return .secondary
        }
        if model.currentIntervalPercentageUsed >= 100 { return .red }
        if model.currentIntervalPercentageUsed >= 80 { return .orange }
        if model.currentIntervalPercentageUsed > 0 && model.currentIntervalPercentageRemaining <= warningThreshold { return .orange }
        if model.currentIntervalPercentageUsed > 0 { return .green }
        return .secondary
    }

    /// 周窗口才画天分隔线：返回 6 个位置（1/7..6/7）
    private func weeklyDayMarkerPercents() -> [Double] {
        guard !model.isShortCurrentInterval else { return [] }
        guard let duration = model.currentIntervalDuration, duration > 0 else { return [] }
        let totalDays = duration / 86_400
        let wholeDays = Int(totalDays)
        guard wholeDays >= 2 else { return [] }
        return (1..<wholeDays).map { Double($0) * 100.0 / totalDays }
    }

    /// reset time 行里 pace 文字颜色：reserve（你有余量）用 secondary 灰，
    /// deficit（你快用完）用红色提醒
    private func paceLabelColor(paceStage: UsagePace.Stage) -> Color {
        switch paceStage {
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
    let language: AppLanguage
    let isHovered: Bool

    @State private var hoverLocation: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let layout = QuotaChartLayout(size: geometry.size)

            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawBackground(context: &context, layout: layout)
                    drawAxes(context: &context, layout: layout)
                    drawHourlyTicks(context: &context, layout: layout)
                    drawPaceGuide(context: &context, layout: layout)
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

        let yAxisMax = model.currentIntervalYAxisMax
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
            : axisLabel("\(model.currentIntervalTotal)")
        context.draw(topLabel, at: CGPoint(x: layout.leftAxisLabelX, y: layout.plotRect.minY), anchor: .leading)
        context.draw(axisLabel("0"), at: CGPoint(x: layout.leftAxisLabelX, y: layout.plotRect.maxY), anchor: .leading)

        if let startTime = model.startTime, let endTime = model.endTime {
            context.draw(axisLabel(axisTimeText(for: startTime)), at: CGPoint(x: layout.plotRect.minX, y: layout.axisLabelY), anchor: .topLeading)
            context.draw(axisLabel(axisTimeText(for: endTime)), at: CGPoint(x: layout.plotRect.maxX, y: layout.axisLabelY), anchor: .topTrailing)
        }
    }

    /// x 轴整点分隔线：5h 窗口画 4 道（1h..4h），2h 窗口画 1 道（1h），1h 及以下不画
    /// 虚线常驻，"1h/2h/3h/4h" 文字标签 hover 时才出
    private func drawHourlyTicks(context: inout GraphicsContext, layout: QuotaChartLayout) {
        guard let ticks = hourlyTickPositions(), !ticks.isEmpty else { return }

        for tick in ticks {
            let x = layout.plotRect.minX + layout.plotRect.width * tick.ratio
            var path = Path()
            path.move(to: CGPoint(x: x, y: layout.plotRect.minY))
            path.addLine(to: CGPoint(x: x, y: layout.plotRect.maxY))
            context.stroke(
                path,
                with: .color(Color.primary.opacity(0.10)),
                style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            if isHovered {
                context.draw(
                    axisLabel(tick.label),
                    at: CGPoint(x: x, y: layout.axisLabelY - 11),
                    anchor: .center)
            }
        }
    }

    private func hourlyTickPositions() -> [(ratio: Double, label: String)]? {
        guard let startTime = model.startTime, let endTime = model.endTime else { return nil }
        let duration = endTime.timeIntervalSince(startTime)
        let totalHours = Int(duration / 3600)
        guard totalHours >= 2, totalHours <= 24 else { return nil }
        return (1..<totalHours).map { hour in
            (ratio: Double(hour) * 3600 / duration, label: "\(hour)h")
        }
    }

    /// 匀速消耗参考线：从左上到右下的对角虚线，代表"匀速消耗下 remaining
    /// 从周期起点 100% 线性下降到周期终点 0% 的轨迹"。颜色按 ahead/behind 区分。
    /// 文字标签不在图里显示，统一挪到 reset time 那一行（避免被 Canvas 边缘裁切）。
    /// onTrack 时也常驻 — 这是"参考线"而非"偏差警示线"。
    private func drawPaceGuide(context: inout GraphicsContext, layout: QuotaChartLayout) {
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

    private func drawHoveredGuide(context: inout GraphicsContext, layout: QuotaChartLayout) {
        guard let hoveredSample = hoveredSample(in: layout) else { return }

        let point = plottedPoint(for: hoveredSample, layout: layout)

        var guide = Path()
        guide.move(to: CGPoint(x: point.x, y: layout.plotRect.minY))
        guide.addLine(to: CGPoint(x: point.x, y: layout.plotRect.maxY))
        context.stroke(guide, with: .color(tint.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

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
        guard let startTime = model.startTime, let endTime = model.endTime else {
            return layout.plotRect.minX
        }

        let totalDuration = max(endTime.timeIntervalSince(startTime), 1)
        let elapsed = min(max(date.timeIntervalSince(startTime), 0), totalDuration)
        let ratio = elapsed / totalDuration
        return layout.plotRect.minX + layout.plotRect.width * ratio
    }

    private func yPosition(forRemaining remaining: Double, layout: QuotaChartLayout) -> CGFloat {
        let yAxisMax = model.currentIntervalYAxisMax
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
