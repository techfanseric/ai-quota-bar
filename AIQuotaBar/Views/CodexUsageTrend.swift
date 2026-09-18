import SwiftUI
import Charts
import CodexLocalUsageCore

@MainActor
struct CodexLocalUsageMenuCard: View {
    @Bindable var model: CodexLocalUsageModel
    let language: AppLanguage
    @State private var days = 7
    private func t(_ zh: String, _ en: String) -> String { language == .simplifiedChinese ? zh : en }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(t("当前账号 · 本机用量", "Current account · This Mac")).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                if model.scanning { ProgressView().controlSize(.mini) }
                Spacer()
                Picker(t("历史范围", "History range"), selection: $days) {
                    Text(t("今天", "Today")).tag(1)
                    Text(t("7 天", "7 days")).tag(7)
                    Text(t("30 天", "30 days")).tag(30)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 155).controlSize(.mini)
            }
            if model.currentAccountID != nil {
                CodexUsageTrend(model: model, language: language, days: days, currentAccount: true)
            } else {
                Text(t("未识别到当前 Codex 账号", "Current Codex account unavailable"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let error = model.error { Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(2) }
        }.onAppear { model.refreshCurrentAccount() }
    }
}

@MainActor
struct CodexUsageTrend: View {
    @Bindable var model: CodexLocalUsageModel
    let language: AppLanguage
    let days: Int
    var currentAccount = false
    @State private var metric = Metric.tokens
    @State private var selectedDate: Date?
    enum Metric: String, CaseIterable { case tokens, records, cache, cost }
    private func t(_ zh: String, _ en: String) -> String { language == .simplifiedChinese ? zh : en }
    private func label(_ metric: Metric) -> String {
        switch metric {
        case .tokens: return "Tokens"
        case .records: return t("用量记录", "Records")
        case .cache: return t("缓存命中率", "Cache hit")
        case .cost: return t("估算成本", "Est. cost")
        }
    }
    private func value(_ summary: UsageSummary) -> Double? {
        switch metric {
        case .tokens: return Double(summary.tokens.total)
        case .records: return Double(summary.records)
        case .cache: return summary.cacheHitRate.map { $0 * 100 }
        case .cost: return summary.records == 0 ? 0 : (summary.pricedRecords == summary.records ? NSDecimalNumber(decimal: summary.cost).doubleValue : nil)
        }
    }
    private func formatted(_ summary: UsageSummary) -> String {
        guard let value = value(summary) else { return metric == .cost ? t("价格不完整", "Incomplete pricing") : "—" }
        switch metric {
        case .cache: return String(format: "%.1f%%", value)
        case .cost: return String(format: "$%.4f", value)
        default: return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        }
    }
    var body: some View {
        let buckets = model.history(days: days, currentAccount: currentAccount)
        let selected = selectedDate.flatMap { date in buckets.first { date >= $0.start && date < $0.end } }
        let total = model.rangeSummary(days: days, currentAccount: currentAccount)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                ForEach(Metric.allCases, id: \.self) { item in
                    Button { metric = item } label: {
                        Text(label(item)).font(.system(size: 10, weight: metric == item ? .semibold : .regular))
                            .foregroundStyle(metric == item ? Color.primary : .secondary)
                    }.buttonStyle(.plain).accessibilityAddTraits(metric == item ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(formatted(selected?.summary ?? total)).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(label(metric)).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text(selected.map { dateLabel($0.start) } ?? (days == 1 ? t("今天 · 按小时", "Today · Hourly") : t("近 \(days) 天 · 按天", "\(days) days · Daily")))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(buckets) { bucket in
                    if let amount = value(bucket.summary) {
                        if metric == .cache {
                            PointMark(x: .value("Time", bucket.start), y: .value(label(metric), amount))
                                .symbolSize(16).foregroundStyle(Color.green)
                        } else {
                            BarMark(x: .value("Time", bucket.start, unit: days == 1 ? .hour : .day), y: .value("Usage", amount), width: .ratio(0.8))
                                .foregroundStyle(Color.green.opacity(0.65))
                        }
                    }
                }
                if let selected {
                    RuleMark(x: .value("Selected", selected.start)).foregroundStyle(.secondary.opacity(0.5))
                }
            }
            .chartXScale(domain: (buckets.first?.start ?? Date())...(buckets.last?.end ?? Date().addingTimeInterval(1)))
            .chartYScale(domain: 0...(metric == .cache ? 100 : max(1, buckets.compactMap { value($0.summary) }.max() ?? 1)))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: days == 1 ? 4 : 3)) { axis in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.1))
                    AxisValueLabel {
                        if let date = axis.as(Date.self) { Text(dateLabel(date)).font(.system(size: 8)) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { axis in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                    AxisValueLabel {
                        if let amount = axis.as(Double.self) { Text(amount.formatted(.number.notation(.compactName))).font(.system(size: 8)) }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                if let frame = proxy.plotFrame {
                                    let rect = geometry[frame]
                                    selectedDate = rect.contains(point) ? proxy.value(atX: point.x - rect.minX) : nil
                                }
                            case .ended: selectedDate = nil
                            }
                        }
                }
            }
            .frame(height: 94)
            .accessibilityLabel(t("本机历史用量", "Local usage history"))
            if model.lastScan == nil && model.events.isEmpty {
                Text(model.scanning ? t("正在读取历史…", "Reading history…") : t("等待首次扫描", "Waiting for first scan")).font(.caption2).foregroundStyle(.secondary)
            } else if metric == .cost && total.pricedRecords < total.records {
                Text(t("未定价时段留空 · 价格覆盖 \(total.pricedRecords)/\(total.records) 条", "Unpriced intervals are blank · Coverage \(total.pricedRecords)/\(total.records)"))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            } else {
                Text(t("悬停查看历史 · 当前时段尚未结束", "Hover to inspect · Current interval is incomplete"))
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }.tint(.primary).onChange(of: days) { _, _ in selectedDate = nil }
    }
    private func dateLabel(_ date: Date) -> String {
        days == 1 ? date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()) : date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
    }
}

@MainActor
struct CodexUsageAccountPicker: View {
    @Bindable var model: CodexLocalUsageModel
    let language: AppLanguage
    private var chinese: Bool { language == .simplifiedChinese }
    var body: some View {
        Picker(chinese ? "账号" : "Account", selection: $model.selectedAccount) {
            Text(chinese ? "全部账号" : "All accounts").tag("all")
            Text(chinese ? "账号未知" : "Unknown account").tag("unknown")
            ForEach(model.accountIDs, id: \.self) { id in
                Text((model.accountLabels[id] ?? (chinese ? "账号" : "Account")) + " · " + String(id.prefix(6))).tag(id)
            }
        }.font(.system(size: 10)).controlSize(.mini).tint(.primary)
            .help(chinese ? "历史日志无账号字段时保持未知；登录观测归属是本机推断，非服务端账单。" : "History without account evidence stays unknown. Login-based attribution is local inference, not provider billing.")
    }
}
