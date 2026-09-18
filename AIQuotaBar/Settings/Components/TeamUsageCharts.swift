import SwiftUI
import CodexLocalUsageCore

/// Server-aggregated team data; the same activity renderer as the local menu.
@MainActor struct TeamUsageCharts: View {
    @Bindable var model: CodexLocalUsageModel
    let language: AppLanguage
    @State private var member = "all"
    @State private var device = "all"
    @State private var account = "all"
    @State private var metric = "tokens"
    @State private var historical = false
    @State private var date = Date()
    @State private var now = Date()
    @State private var daily: [UsageHistoryBucket] = []
    @State private var hourly: [UsageHistoryBucket] = []
    @State private var loading = false
    @State private var error: String?
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }
    private func t(_ zh: String, _ en: String) -> String { language == .simplifiedChinese ? zh : en }
    private var requestKey: String { "\(model.connection?.binding ?? "")|\(member)|\(device)|\(account)|\(historical)|\(historical ? date.timeIntervalSince1970 : 0)|\(now.timeIntervalSince1970)" }
    private func amount(_ row: TeamUsageRow) -> Double? {
        switch metric {
        case "records": return Double(row.records)
        case "cache": return row.cacheHitRate.map { $0 * 100 }
        case "cost": return row.records == row.pricedRecords ? row.costUSD : nil
        default: return Double(row.input + row.output)
        }
    }
    private func label(_ value: Double?) -> String {
        guard let value else { return metric == "cost" ? t("未完整定价", "Not fully priced") : "—" }
        if metric == "cache" { return String(format: "%.1f%%", value) }
        if metric == "cost" { return String(format: "$%.4f", value) }
        return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(t("成员用量对比", "Compare members")).font(.headline)
                Spacer()
                Picker(t("指标", "Metric"), selection: $metric) {
                    Text("Tokens").tag("tokens"); Text(t("记录数", "Records")).tag("records")
                    Text(t("缓存命中", "Cache hit")).tag("cache"); Text(t("估算成本", "Est. cost")).tag("cost")
                }.frame(maxWidth: 190)
            }
            let rows = model.teamRows.sorted { (amount($0) ?? -1) > (amount($1) ?? -1) }
            let maximum = metric == "cache" ? 100 : max(1, rows.compactMap(amount).max() ?? 1)
            ForEach(rows) { row in
                Button { member = row.id; device = "all" } label: {
                    HStack(spacing: 10) {
                        Text(row.name).frame(width: 110, alignment: .leading).lineLimit(1).help(row.name)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.06))
                                Capsule().fill(member == row.id ? Color.accentColor : .green.opacity(0.65))
                                    .frame(width: geometry.size.width * min(1, max(0, amount(row) ?? 0) / maximum))
                            }
                        }.frame(height: 9)
                        Text(label(amount(row))).font(.caption.monospacedDigit()).frame(width: 96, alignment: .trailing)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(row.name + " · " + label(amount(row)))
            }
            Divider()
            HStack {
                Picker(t("成员", "Member"), selection: $member) {
                    Text(t("整个团队", "Whole team")).tag("all")
                    ForEach(model.teamRows) { Text($0.name).tag($0.id) }
                }
                Picker(t("设备", "Device"), selection: $device) {
                    Text(t("全部设备", "All devices")).tag("all")
                    ForEach(model.teamDevices.filter { member == "all" || $0.memberID == member }) { Text(String($0.name.prefix(16))).tag($0.id) }
                }
            }
            Picker(t("账号", "Account"), selection: $account) {
                Text(t("全部账号", "All accounts")).tag("all")
                ForEach(model.teamAccounts) { Text($0.id == "unknown" ? t("账号未知", "Unknown account") : $0.id).tag($0.id) }
            }
            HStack {
                Toggle(t("查看指定日期", "Inspect a date"), isOn: $historical).toggleStyle(.checkbox)
                if historical {
                    DatePicker("UTC", selection: $date, in: ...Date(), displayedComponents: .date)
                        .environment(\.timeZone, calendar.timeZone).environment(\.calendar, calendar)
                }
                Spacer()
                Button(t("刷新图表", "Refresh charts")) { now = Date() }.disabled(loading)
                if loading { ProgressView().controlSize(.small) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if !daily.isEmpty {
                CodexUsageActivityView(daily: daily, hourly: hourly, total: UsageActivityLayout.summary(daily), language: language,
                    now: now, calendar: calendar, hourlyCaption: historical ? t("所选日期", "Selected day") : nil,
                    onSelectDay: { date = $0; historical = true })
                    .frame(maxWidth: 620, alignment: .leading)
                let total = UsageActivityLayout.summary(daily)
                Text(t("本月输入 ", "Month input ") + total.tokens.input.formatted() + t(" · 输出 ", " · Output ") + total.tokens.output.formatted()
                    + t(" · 缓存读取 ", " · Cached input ") + total.tokens.cached.formatted()
                    + t(" · 推理 ", " · Reasoning ") + total.tokens.reasoning.formatted()).font(.caption).foregroundStyle(.secondary)
                Text(t("定价覆盖 ", "Price coverage ") + "\(total.pricedRecords)/\(total.records)").font(.caption).foregroundStyle(.secondary)
            }
            Text(t("UTC 时间 · 点击成员条形图或日期可细看；每格 5 分钟。仅已上报数据，输入已含缓存、输出已含推理。", "UTC · Select a member or calendar day to inspect 5-minute cells. Reported usage only; input includes cache and output includes reasoning."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: requestKey) {
            let key = requestKey; loading = true; error = nil; daily = []; hourly = []
            do {
                let result = try await model.teamActivity(member: member == "all" ? nil : member, device: device == "all" ? nil : device,
                    account: account == "all" ? nil : account, date: historical ? date : nil, now: now)
                guard !Task.isCancelled, key == requestKey else { return }
                daily = result.daily; hourly = result.hourly; loading = false
            } catch {
                guard !Task.isCancelled, key == requestKey else { return }
                self.error = error.localizedDescription; loading = false
            }
        }
        .onChange(of: member) { _, _ in device = "all" }
        .onChange(of: model.connection?.binding) { _, _ in member = "all"; device = "all"; account = "all" }
        .onChange(of: model.teamUpdatedAt) { _, _ in
            if member != "all" && !model.teamRows.contains(where: { $0.id == member }) { member = "all"; device = "all" }
            if account != "all" && !model.teamAccounts.contains(where: { $0.id == account }) { account = "all" }
            now = Date()
        }
    }
}
