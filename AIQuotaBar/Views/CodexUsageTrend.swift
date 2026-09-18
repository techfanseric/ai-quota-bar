import SwiftUI
import CodexLocalUsageCore

@MainActor
struct CodexLocalUsageMenuCard: View {
    @Bindable var model: CodexLocalUsageModel
    let language: AppLanguage
    private var chinese: Bool { language == .simplifiedChinese }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(chinese ? "本机用量" : "Local usage")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    .help(chinese ? "当前 Codex 账号在这台 Mac 上的用量" : "Current Codex account usage on this Mac")
                if model.scanning { ProgressView().controlSize(.mini) }
                Spacer()
                Text(chinese ? "近 30 天" : "30 days").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            if model.currentAccountID != nil {
                CodexUsageTrend(model: model, language: language, currentAccount: true)
            } else {
                Text(chinese ? "登录 Codex 后显示当前账号用量；历史可在设置中查看。" : "Sign in to Codex to see this account’s usage. History remains in Settings.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let error = model.error { Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
        }.onAppear { model.refreshCurrentAccount() }
    }
}

@MainActor
struct CodexUsageTrend: View {
    @Bindable var model: CodexLocalUsageModel
    let language: AppLanguage
    var currentAccount = false
    var body: some View {
        CodexUsageActivityView(
            daily: model.history(days: 30, currentAccount: currentAccount),
            hourly: model.history(days: 1, currentAccount: currentAccount),
            total: model.rangeSummary(days: 30, currentAccount: currentAccount), language: language)
    }
}

/// Calendar-aligned contribution cells. Missing padding never masquerades as zero usage.
enum UsageActivityLayout {
    static func slots(dates: [Date], calendar: Calendar = .current) -> [Int?] {
        guard let first = dates.first else { return [] }
        let offset = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        var values = Array<Int?>(repeating: nil, count: offset) + dates.indices.map { Optional($0) }
        while values.count % 7 != 0 { values.append(nil) }
        return values
    }
    static func intensity(value: Double?, maximum: Double) -> Double? {
        guard let value else { return nil }
        guard value > 0 else { return 0 }
        return max(0.25, min(1, ceil(value / max(1, maximum) * 4) / 4))
    }
}

@MainActor
struct CodexUsageActivityView: View {
    let daily: [UsageHistoryBucket]
    let hourly: [UsageHistoryBucket]
    let total: UsageSummary
    let language: AppLanguage
    @State private var metric = Metric.tokens
    @State private var selectedDay: Int?
    @State private var selectedHour: Int?
    enum Metric: String, CaseIterable { case tokens, records, cache, cost }
    private func t(_ zh: String, _ en: String) -> String { language == .simplifiedChinese ? zh : en }
    private func label(_ item: Metric) -> String {
        switch item { case .tokens: return "Tokens"; case .records: return t("用量记录", "Records"); case .cache: return t("缓存命中", "Cache hit"); case .cost: return t("估算成本", "Est. cost") }
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
        guard let value = value(summary) else { return metric == .cost ? t("未定价", "Unpriced") : "—" }
        switch metric { case .cache: return String(format: "%.1f%%", value); case .cost: return String(format: "$%.4f", value); default: return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }
    }
    private var selected: UsageHistoryBucket? {
        if let index = selectedHour, hourly.indices.contains(index) { return hourly[index] }
        if let index = selectedDay, daily.indices.contains(index) { return daily[index] }
        return nil
    }
    private var tint: Color { .green }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ForEach(Metric.allCases, id: \.self) { item in
                    Button { metric = item } label: {
                        Text(label(item)).font(.system(size: 10, weight: metric == item ? .semibold : .regular))
                            .foregroundStyle(metric == item ? Color.primary : .secondary).lineLimit(1)
                    }.buttonStyle(.plain).accessibilityAddTraits(metric == item ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .center, spacing: 16) {
                matrix
                VStack(alignment: .leading, spacing: 5) {
                    Text(selected.map { dateLabel($0.start, hourly: selectedHour != nil) } ?? t("近 30 天合计", "30-day total"))
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    Text(formatted(selected?.summary ?? total))
                        .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
                    Text(label(metric)).font(.system(size: 9)).foregroundStyle(.secondary)
                    HStack(spacing: 3) {
                        Text(t("少", "Less"))
                        ForEach(0..<5) { level in RoundedRectangle(cornerRadius: 1).fill(level == 0 ? Color.primary.opacity(0.07) : tint.opacity(Double(level) / 4 * 0.8)).frame(width: 7, height: 7) }
                        Text(t("多", "More"))
                    }.font(.system(size: 8)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Text(t("今天", "Today"))
                Spacer()
                Text(t("按小时 · 悬停查看", "Hourly · Hover to inspect"))
            }.font(.system(size: 9)).foregroundStyle(.secondary)
            hourlyBars
            if metric == .cost && total.pricedRecords < total.records {
                Text(t("斜线为未定价 · 覆盖 \(total.pricedRecords)/\(total.records) 条", "Hatched = unpriced · Coverage \(total.pricedRecords)/\(total.records)"))
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            } else if total.records == 0 {
                Text(t("尚无用量记录；使用 Codex 后会自动出现。", "No records yet. Usage appears after you use Codex."))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }.onChange(of: daily.first?.start) { _, _ in selectedDay = nil; selectedHour = nil }
    }
    private var matrix: some View {
        let slots = UsageActivityLayout.slots(dates: daily.map(\.start))
        let maximum = metric == .cache ? 100 : daily.compactMap { value($0.summary) }.max() ?? 1
        return HStack(alignment: .top, spacing: 3) {
            ForEach(0..<(slots.count / 7), id: \.self) { column in
                VStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { row in
                        if let index = slots[column * 7 + row] {
                            dayCell(index: index, maximum: maximum)
                        } else { Color.clear.frame(width: 10, height: 10).accessibilityHidden(true) }
                    }
                }
            }
        }.padding(.vertical, 4)
            .overlay(alignment: .topLeading) {
                if let index = selectedDay, daily.indices.contains(index) {
                    CycleCallout(text: dateLabel(daily[index].start) + " · " + formatted(daily[index].summary))
                        .fixedSize().offset(y: -20).allowsHitTesting(false)
                }
            }
    }
    private func dayCell(index: Int, maximum: Double) -> some View {
        let bucket = daily[index]
        let text = dateLabel(bucket.start) + " · " + formatted(bucket.summary) + " " + label(metric)
        let border = selectedDay == index ? Color.primary.opacity(0.5) : Color.clear
        return Button { selectedDay = selectedDay == index ? nil : index; selectedHour = nil } label: {
            cell(amount: value(bucket.summary), maximum: maximum)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(border, lineWidth: 1))
        }.buttonStyle(.plain)
            .onHover { over in selectedDay = over ? index : nil }
            .accessibilityLabel(text)
    }
    private func cell(amount: Double?, maximum: Double) -> some View {
        let intensity = UsageActivityLayout.intensity(value: amount, maximum: maximum)
        return RoundedRectangle(cornerRadius: 2)
            .fill(intensity == nil || intensity == 0 ? Color.primary.opacity(0.07) : tint.opacity((intensity ?? 0) * 0.8))
            .overlay {
                if intensity == nil { Path { p in p.move(to: CGPoint(x: 2, y: 8)); p.addLine(to: CGPoint(x: 8, y: 2)) }.stroke(Color.secondary.opacity(0.5), lineWidth: 1) }
            }.frame(width: 10, height: 10)
    }
    private var hourlyBars: some View {
        let maximum = metric == .cache ? 100 : max(1, hourly.compactMap { value($0.summary) }.max() ?? 1)
        let calendar = Calendar.current
        let start = hourly.first?.start ?? calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))!
        let count = calendar.dateComponents([.hour], from: calendar.startOfDay(for: start), to: end).hour ?? 24
        return GeometryReader { geometry in
            let width = min(10, max(3, (geometry.size.width - CGFloat(count - 1) * 2) / CGFloat(count)))
            let startX = (geometry.size.width - CGFloat(count) * width - CGFloat(count - 1) * 2) / 2
            ZStack(alignment: .topLeading) {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<count, id: \.self) { index in
                        let bucket = hourly.indices.contains(index) ? hourly[index] : nil
                        let amount = bucket.flatMap { value($0.summary) }
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(bucket == nil ? 0.025 : 0.07))
                            if let amount, amount > 0 {
                                RoundedRectangle(cornerRadius: 1.5).fill(tint.opacity(0.65)).frame(height: min(20, 20 * amount / maximum))
                            } else if bucket != nil && amount == nil {
                                Text("/").font(.system(size: 8)).foregroundStyle(.tertiary)
                            }
                        }.frame(width: width, height: 20).contentShape(Rectangle())
                            .onHover { over in selectedHour = over && bucket != nil ? index : nil }
                            .help(bucket.map { dateLabel($0.start, hourly: true) + " · " + formatted($0.summary) } ?? t("尚未到来", "Upcoming"))
                            .accessibilityLabel(bucket.map { dateLabel($0.start, hourly: true) + " · " + formatted($0.summary) } ?? t("尚未到来", "Upcoming"))
                    }
                }.padding(.top, 10).frame(maxWidth: .infinity)
                if let index = selectedHour, hourly.indices.contains(index) {
                    CycleCallout(text: dateLabel(hourly[index].start, hourly: true) + " · " + formatted(hourly[index].summary))
                        .position(x: min(max(startX + (CGFloat(index) + 0.5) * (width + 2), 84), geometry.size.width - 84), y: 6)
                }
            }
        }.frame(height: 30)
    }
    private func dateLabel(_ date: Date, hourly: Bool = false) -> String {
        hourly ? date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()) : date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
    }
}

/// Samples never enter a model, database, upload queue or account selection.
@MainActor
struct LocalUsageSamplePreview: View {
    let language: AppLanguage
    static func events(now: Date = Date(), calendar: Calendar = .current) -> [LocalUsageEvent] {
        (0..<30).flatMap { day -> [LocalUsageEvent] in
            guard day % 6 != 3 else { return [] }
            let start = calendar.date(byAdding: .day, value: -day, to: calendar.startOfDay(for: now))!
            return [0, 3, 7, 10, 14, 18, 21].compactMap { hour in
                let date = calendar.date(byAdding: .hour, value: hour, to: start)!
                guard date <= now else { return nil }
                return LocalUsageEvent(id: "sample-\(day)-\(hour)", occurredAt: UsageTime.string(date), model: "sample-model", tokens: UsageTokens(input: Int64((day % 5 + 1) * 1400 + hour * 200), cached: 700, output: 800), accountID: "sample")
            }
        }
    }
    var body: some View {
        let events = Self.events()
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text(language == .simplifiedChinese ? "示例数据 · 不保存、不上传" : "Sample data · Never saved or uploaded")
                .font(.system(size: 9)).foregroundStyle(.secondary)
            CodexUsageActivityView(daily: UsageHistory.buckets(events: events, prices: [], days: 30), hourly: UsageHistory.buckets(events: events, prices: [], days: 1), total: UsageSummary(events: events, prices: []), language: language)
        }
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
