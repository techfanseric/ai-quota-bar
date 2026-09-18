import SwiftUI
import CodexLocalUsageCore

@MainActor
struct CodexLocalUsageMenuCard: View {
    @Bindable var model: CodexLocalUsageModel
    let language: AppLanguage
    private var chinese: Bool { language == .simplifiedChinese }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
        TimelineView(.periodic(from: .now, by: 60)) { context in
            CodexUsageActivityView(
                daily: model.activityHistory(month: true, currentAccount: currentAccount, now: context.date),
                hourly: model.activityHistory(month: false, currentAccount: currentAccount, now: context.date),
                total: model.monthSummary(currentAccount: currentAccount, now: context.date),
                language: language, now: context.date, showsLocalLabel: currentAccount,
                subscription: CodexSubscriptionStatus.shared.marker(
                    accountID: currentAccount ? model.currentAccountID : model.selectedAccount,
                    now: context.date),
                resets: CodexResetHistory.shared.markers)
        }
        .frame(maxWidth: 420, alignment: .leading)
        .onAppear { CodexResetHistory.shared.refreshIfNeeded() }
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
    static func summary(_ buckets: [UsageHistoryBucket]) -> UsageSummary {
        buckets.reduce(into: UsageSummary()) { result, bucket in
            let value = bucket.summary
            result.records += value.records
            result.estimatedRecords += value.estimatedRecords
            result.tokens = result.tokens + value.tokens
            result.pricedRecords += value.pricedRecords
            result.cost += value.cost
            for (model, tokens) in value.byModel { result.byModel[model, default: 0] += tokens }
        }
    }
    static func hasUsableCost(_ buckets: [UsageHistoryBucket]) -> Bool {
        buckets.contains { $0.summary.records > 0 && $0.summary.pricedRecords == $0.summary.records }
    }
    static func intensity(value: Double?, maximum: Double) -> Double? {
        guard let value else { return nil }
        guard value > 0 else { return 0 }
        return max(0.25, min(1, ceil(value / max(1, maximum) * 4) / 4))
    }
    /// Tooltip origin (top-leading, in container space) hugging the hovered
    /// cell: above it by default, flipping below inside the top rows, x
    /// centered on the cell and clamped to the container. A container narrower
    /// than the bubble hugs its leading edge (the month grid sits at the
    /// panel's leading edge) or trailing edge (the 24-column grid at the
    /// trailing edge), mirroring ModelUtilizationBarsView.calloutPosition.
    static func calloutOrigin(cell: CGRect, container: CGSize, callout: CGSize, hugsLeading: Bool) -> CGPoint {
        let spacing: CGFloat = 4
        let x: CGFloat
        if container.width >= callout.width {
            x = min(max(cell.midX - callout.width / 2, 0), container.width - callout.width)
        } else {
            x = hugsLeading ? 0 : container.width - callout.width
        }
        let above = cell.minY - callout.height - spacing
        let y = above >= 0 ? above : min(cell.maxY + spacing, max(0, container.height - callout.height))
        return CGPoint(x: x, y: y)
    }
}

@MainActor
struct CodexUsageActivityView: View {
    let daily: [UsageHistoryBucket]
    let hourly: [UsageHistoryBucket]
    let total: UsageSummary
    let language: AppLanguage
    var now: Date = Date()
    var showsLocalLabel = false
    var subscription: CodexSubscriptionMarker? = nil
    var resets: [CodexResetMarker] = []
    var calendar: Calendar = .current
    var hourlyCaption: String? = nil
    var onSelectDay: ((Date) -> Void)? = nil
    @State private var metric = Metric.tokens
    @State private var selectedDay: Int?
    @State private var selectedHour: Int?
    enum Metric: String, CaseIterable { case tokens, records, cache, cost }
    /// Dark green keeps reset frames apart from the black renewal dash and
    /// selection ring; same accent as the website.
    private static let resetGreen = Color(red: 70 / 255, green: 116 / 255, blue: 87 / 255)
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
        if let index = selectedDay, daily.indices.contains(index), daily[index].start <= now { return daily[index] }
        return nil
    }
    private var visibleMetrics: [Metric] {
        UsageActivityLayout.hasUsableCost(daily + hourly) ? Metric.allCases : Metric.allCases.filter { $0 != .cost }
    }
    private var tint: Color { .green }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: showsLocalLabel ? 7 : 10) {
                if showsLocalLabel {
                    Text(t("本机", "Local")).font(.system(size: 9)).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                ForEach(visibleMetrics, id: \.self) { item in
                    Button { metric = item } label: {
                        Text(label(item)).font(.system(size: 10, weight: metric == item ? .semibold : .regular))
                            .foregroundStyle(metric == item ? Color.primary : .secondary).lineLimit(1)
                    }.buttonStyle(.plain).accessibilityAddTraits(metric == item ? .isSelected : [])
                }
                if !showsLocalLabel { Spacer(minLength: 0) }
            }
            HStack(alignment: .top, spacing: 5) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(calendarLabel(daily.first?.start ?? now, format: "MMM"))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    matrix
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(hourlyCaption ?? t("近 \(hourly.count / 12)h", "Last \(hourly.count / 12)h"))
                        Spacer(minLength: 2)
                        Text(t("每格 5m", "5m / cell")).foregroundStyle(.tertiary)
                    }.font(.system(size: 9)).foregroundStyle(.secondary)
                    hourlyBars
                }.frame(maxWidth: .infinity)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let selected {
                    summaryValue(dateLabel(selected.start, hourly: selectedHour != nil), selected.summary)
                    Text(label(metric)).font(.system(size: 9)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    summaryValue(t("本月", "Month"), total)
                    Spacer(minLength: 6)
                    summaryValue(hourlyCaption ?? t("近 24h", "Last 24h"), UsageActivityLayout.summary(hourly))
                }
            }
            if metric == .cost && total.pricedRecords < total.records {
                Text(t("未定价 / 覆盖 \(total.pricedRecords)/\(total.records) 条", "Unpriced / coverage \(total.pricedRecords)/\(total.records)"))
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            } else if total.records == 0 {
                Text(t("尚无用量记录；使用 Codex 后会自动出现。", "No records yet. Usage appears after you use Codex."))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }.onChange(of: daily.first?.start) { _, _ in selectedDay = nil; selectedHour = nil }
         .onChange(of: visibleMetrics) { _, metrics in if !metrics.contains(metric) { metric = .tokens } }
         .onChange(of: hourly.first?.start) { _, _ in selectedHour = nil }
    }
    /// Matches the clamping convention in ModelUtilizationBarsView: estimate
    /// the bubble size instead of measuring; overshooting only clamps early.
    private static let calloutSize = CGSize(width: 232, height: 18)
    private func summaryValue(_ title: String, _ summary: UsageSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(formatted(summary))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }
    }
    private var matrix: some View {
        let slots = UsageActivityLayout.slots(dates: daily.map(\.start), calendar: calendar)
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
        }
            .overlay(alignment: .topLeading) {
                if let index = selectedDay, daily.indices.contains(index), let slot = slots.firstIndex(of: index) {
                    let origin = UsageActivityLayout.calloutOrigin(
                        cell: CGRect(x: CGFloat(slot / 7) * 13, y: CGFloat(slot % 7) * 13, width: 10, height: 10),
                        container: CGSize(width: CGFloat(slots.count / 7) * 13 - 3, height: 88),
                        callout: Self.calloutSize, hugsLeading: true)
                    CycleCallout(text: dayCallout(index))
                        .fixedSize().offset(x: origin.x, y: origin.y).allowsHitTesting(false)
                }
            }
    }
    private func dayCell(index: Int, maximum: Double) -> some View {
        let bucket = daily[index]
        let text = dateLabel(bucket.start) + " · " + formatted(bucket.summary) + " " + label(metric)
        let future = bucket.start > now
        let marker = subscription.flatMap { calendar.isDate($0.date, inSameDayAs: bucket.start) ? $0 : nil }
        let billingLabel = marker.map { $0.renews ? t("自动续费", "Auto-renews") : t("订阅到期 · 不续费", "Expires · No renewal") }
        let reset = resets.first { calendar.isDate($0.date, inSameDayAs: bucket.start) }
        let resetNote = reset.map { dateLabel($0.announcedAt, hourly: true) + " " + t("已重置", "reset") }
        let notes = [billingLabel, resetNote].compactMap { $0 }
        let border = selectedDay == index ? Color.primary.opacity(0.5) : Color.clear
        let helpText: String
        if let resetNote {
            helpText = ([resetNote, billingLabel].compactMap { $0 }).joined(separator: " · ")
        } else {
            helpText = billingLabel.map { dateLabel(bucket.start) + " · " + $0 } ?? text
        }
        return Button { selectedDay = selectedDay == index ? nil : index; selectedHour = nil; onSelectDay?(bucket.start) } label: {
            cell(amount: value(bucket.summary), maximum: maximum)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(border, lineWidth: 1))
                .overlay {
                    if let marker {
                        RoundedRectangle(cornerRadius: 2).stroke(Color.primary.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: marker.renews ? [2, 1] : []))
                    }
                }
                .overlay {
                    if reset != nil {
                        RoundedRectangle(cornerRadius: 2).stroke(Self.resetGreen, lineWidth: 1)
                    }
                }
                .help(helpText)
        }.buttonStyle(.plain).disabled(future && marker == nil).opacity(future && marker == nil ? 0.25 : 1)
            .onHover { over in selectedDay = over && (!future || marker != nil) ? index : nil; if over { selectedHour = nil } }
            .accessibilityLabel(notes.isEmpty ? text : text + " · " + notes.joined(separator: " · "))
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
        return GeometryReader { geometry in
            let columns = hourly.count / 12
            let width = max(1, (geometry.size.width - CGFloat(max(0, columns - 1))) / CGFloat(max(1, columns)))
            HStack(spacing: 1) {
                ForEach(0..<columns, id: \.self) { row in
                    VStack(spacing: 3) {
                        VStack(spacing: 1) {
                            ForEach(0..<12, id: \.self) { segment in
                                let index = row * 12 + segment
                                if hourly.indices.contains(index) {
                                    let bucket = hourly[index]
                                    let amount = value(bucket.summary)
                                    let intensity = UsageActivityLayout.intensity(value: amount, maximum: maximum)
                                    Button { selectedHour = selectedHour == index ? nil : index; selectedDay = nil } label: {
                                        RoundedRectangle(cornerRadius: 0.7)
                                            .fill(intensity == nil || intensity == 0 ? Color.primary.opacity(0.07) : tint.opacity((intensity ?? 0) * 0.8))
                                            .overlay {
                                                if intensity == nil { Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 1).rotationEffect(.degrees(35)) }
                                            }
                                            .overlay(RoundedRectangle(cornerRadius: 0.7).stroke(selectedHour == index ? Color.primary.opacity(0.5) : .clear, lineWidth: 0.7))
                                            .frame(maxWidth: .infinity).frame(height: 6.333333)
                                    }.buttonStyle(.plain)
                                        .onHover { over in selectedHour = over ? index : nil; if over { selectedDay = nil } }
                                        .accessibilityLabel(intervalLabel(bucket) + " · " + formatted(bucket.summary) + " " + label(metric))
                                }
                            }
                        }
                        Text(row.isMultiple(of: 2) ? String(format: "%02d", calendar.component(.hour, from: hourly[row * 12].start)) : " ")
                            .font(.system(size: 7)).monospacedDigit()
                            .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
                            .frame(width: width, height: 9)
                            .accessibilityHidden(true)
                    }.frame(width: width)
                }
            }
            .overlay(alignment: .topLeading) {
                if let index = selectedHour, hourly.indices.contains(index) {
                    let origin = UsageActivityLayout.calloutOrigin(
                        cell: CGRect(x: CGFloat(index / 12) * (width + 1), y: CGFloat(index % 12) * 7.333, width: width, height: 6.333),
                        container: CGSize(width: geometry.size.width, height: 88),
                        callout: Self.calloutSize, hugsLeading: false)
                    CycleCallout(text: intervalLabel(hourly[index]) + " · " + formatted(hourly[index].summary))
                        .fixedSize().offset(x: origin.x, y: origin.y).allowsHitTesting(false)
                }
            }
        }.frame(height: 99)
    }
    private func intervalLabel(_ bucket: UsageHistoryBucket) -> String {
        dateLabel(bucket.start, hourly: true) + "–" + clockLabel(bucket.end)
    }
    private func clockLabel(_ date: Date) -> String {
        calendarLabel(date, format: "HH:mm")
    }
    private func dayCallout(_ index: Int) -> String {
        let bucket = daily[index]
        let marker = subscription.flatMap { calendar.isDate($0.date, inSameDayAs: bucket.start) ? $0 : nil }
        let billing = marker.map { $0.renews ? t("自动续费", "Auto-renews") : t("到期不续费", "Expires; no renewal") }
        if let reset = resets.first(where: { calendar.isDate($0.date, inSameDayAs: bucket.start) }) {
            return ([dateLabel(reset.announcedAt, hourly: true) + " " + t("已重置", "reset"), billing].compactMap { $0 }).joined(separator: " · ")
        }
        return ([dateLabel(bucket.start), bucket.start <= now ? formatted(bucket.summary) : nil, billing].compactMap { $0 }).joined(separator: " · ")
    }
    private func calendarLabel(_ date: Date, format: String) -> String {
        if format == "HH:mm" { return String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date)) }
        if format == "MM/dd" { return String(format: "%02d/%02d", calendar.component(.month, from: date), calendar.component(.day, from: date)) }
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: language == .simplifiedChinese ? "zh_CN" : "en_US"); formatter.dateFormat = format
        return formatter.string(from: date)
    }
    private func dateLabel(_ date: Date, hourly: Bool = false) -> String {
        calendarLabel(date, format: "MM/dd") + (hourly ? " " + clockLabel(date) : "")
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
            CodexUsageActivityView(daily: UsageHistory.month(events: events, prices: []), hourly: UsageHistory.last24Hours(events: events, prices: []), total: UsageSummary(events: events, prices: [], from: Calendar.current.dateInterval(of: .month, for: Date())!.start, to: Date()), language: language, showsLocalLabel: true)
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
