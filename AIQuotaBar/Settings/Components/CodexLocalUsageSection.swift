import SwiftUI
import UniformTypeIdentifiers
import CodexLocalUsageCore

@MainActor
struct CodexLocalUsageSection: View {
    @Bindable var model: CodexLocalUsageModel
    let language: AppLanguage
    @State private var importing = false
    private func t(_ zh: String, _ en: String) -> String { language == .simplifiedChinese ? zh : en }

    var body: some View {
        SettingsSection(title: t("Codex 本机用量", "Codex local usage"),
                        caption: t("来自本机日志，与共享账号额度分开统计。", "Measured from local logs, separately from shared account quota."), contentSpacing: 12) {
            HStack {
                Text(t("本月 · 最近 24 小时", "This month · Last 24h")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.scanning)
                    .help(t("重新扫描本机日志", "Scan local logs"))
            }
            CodexUsageAccountPicker(model: model, language: language)
            Text(t("账号未知的历史不会归给当前登录账号。登录观测仅在相邻采样账号一致且登录文件未变化时归属；切换、休眠和未监测时段保持未知。它不能证明请求实际使用的账号。", "Unknown history is never assigned to the current login. Login observations attribute only intervals with unchanged consecutive auth samples; switches, sleep and unobserved gaps remain unknown. This does not prove the account used by a request."))
                .font(.caption).foregroundStyle(.secondary)
            CodexUsageTrend(model: model, language: language)
            let summary = model.monthSummary()
            HStack(alignment: .top, spacing: 18) {
                metric("Tokens", summary.tokens.total.formatted())
                metric(t("有效用量记录", "Usage records"), summary.records.formatted())
                metric(t("缓存命中率", "Cache hit rate"), summary.cacheHitRate.map { ($0 * 100).formatted(.number.precision(.fractionLength(1))) + "%" } ?? "—")
                metric(t("估算成本", "Estimated cost"), summary.pricedRecords > 0 ? String(format: "$%.4f", NSDecimalNumber(decimal: summary.cost).doubleValue) : t("未定价", "Unpriced"))
            }
            Text(t("输入 \(summary.tokens.input.formatted()) · 输出 \(summary.tokens.output.formatted()) · 缓存读取 \(summary.tokens.cached.formatted()) · 缓存写入 \(summary.tokens.cacheWrite.formatted())", "Input \(summary.tokens.input.formatted()) · Output \(summary.tokens.output.formatted()) · Cache read \(summary.tokens.cached.formatted()) · Cache write \(summary.tokens.cacheWrite.formatted())"))
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text(t("价格覆盖 \(summary.pricedRecords)/\(summary.records) 条；\(summary.estimatedRecords) 条为累计差值。成本为 API 等价估算，用量记录不等于完整 HTTP 请求数。", "Prices cover \(summary.pricedRecords)/\(summary.records) records; \(summary.estimatedRecords) use cumulative deltas. Costs are API-equivalent estimates; records are not complete HTTP request counts."))
                .font(.caption).foregroundStyle(.secondary)
            if summary.records == 0 {
                Text(model.scanning ? t("正在读取本机历史…", "Reading local history…") : t("此时间范围内尚无有效用量记录。", "No usage records in this date range.")).foregroundStyle(.secondary)
            }
            ForEach(summary.byModel.keys.sorted(), id: \.self) { key in
                HStack { Text(key); Spacer(); Text(summary.byModel[key, default: 0].formatted() + " tokens").monospacedDigit() }.font(.caption)
            }
            Text(t("扫描 \(model.files) 个文件 · \(model.issues) 个异常 · \(model.deferred) 个会话待解析 · \(model.incomplete) 个尾行待写完", "\(model.files) files · \(model.issues) issues · \(model.deferred) deferred sessions · \(model.incomplete) incomplete tails"))
                .font(.caption).foregroundStyle(model.issues + model.deferred > 0 ? .orange : .secondary)
            if let at = model.lastScan { Text(t("最近扫描：", "Last scan: ") + at.formatted()).font(.caption).foregroundStyle(.secondary) }
            Button(t("导入模型价格 JSON…", "Import model prices JSON…")) { importing = true }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                    do {
                        let url = try result.get(); let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        model.importPrices(try Data(contentsOf: url))
                    } catch { model.error = error.localizedDescription }
                }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }

        .onChange(of: model.days) { _, _ in model.teamRows = []; model.teamDevices = []; model.teamAccounts = [] }
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(label).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(.body, design: .rounded, weight: .semibold)).monospacedDigit() }
    }
}
