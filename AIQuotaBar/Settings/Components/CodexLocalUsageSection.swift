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
            if let storage = model.storageStats {
                Divider()
                Text(t("本机存储与上传", "Local storage & delivery")).font(.subheadline.weight(.semibold))
                Text(t("占用 \(bytes(storage.totalBytes)) · 数据库 \(bytes(storage.databaseBytes)) · 写入日志与共享内存 \(bytes(storage.journalBytes + storage.sharedMemoryBytes))",
                       "Using \(bytes(storage.totalBytes)) · Database \(bytes(storage.databaseBytes)) · Journal & shared memory \(bytes(storage.journalBytes + storage.sharedMemoryBytes))"))
                    .font(.caption).textSelection(.enabled)
                Text(t("共 \(storage.totalRecords.formatted()) 条 · 云端已确认 \(storage.confirmedRecords.formatted()) · 待上传 \(storage.pendingRecords.formatted()) · 被拒绝 \(storage.rejectedRecords.formatted()) · 仅本地 \(storage.localOnlyRecords.formatted())",
                       "\(storage.totalRecords.formatted()) records · Confirmed \(storage.confirmedRecords.formatted()) · Pending \(storage.pendingRecords.formatted()) · Rejected \(storage.rejectedRecords.formatted()) · Local only \(storage.localOnlyRecords.formatted())"))
                    .font(.caption).foregroundStyle(storage.pendingRecords + storage.rejectedRecords > 0 ? .orange : .secondary)
                Text(t("仅本地记录未分配上传目标，不代表上传失败，也不代表已备份。以上统计包含所有历史绑定；当前团队状态见下方。存储占用不含 Codex 原始会话日志。",
                       "Local-only records have no upload destination; they are neither failed uploads nor cloud backups. Counts include previous bindings; see current team status below. Storage excludes original Codex session logs."))
                    .font(.caption).foregroundStyle(.secondary)
                if let queue = model.quotaQueueStats {
                    Text(t("额度快照重试队列 \(bytes(queue.bytes)) · 当前团队 \(queue.currentTeamFiles) 份 · 其他归属或旧版 \(queue.otherFiles) 份",
                           "Quota retry queue: \(bytes(queue.bytes)) · Current team \(queue.currentTeamFiles) · Other or legacy \(queue.otherFiles)"))
                        .font(.caption).foregroundStyle(queue.currentTeamFiles > 0 ? .orange : .secondary)
                }
                Text(t("另有 Codex 原始日志 \(bytes(model.sourceLogBytes))，由 Codex 管理，本软件只读，不自动清理。",
                       "Original Codex logs: \(bytes(model.sourceLogBytes)), managed by Codex. This app only reads them and never cleans them automatically."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(t("图表仅加载最近 35 天；更早记录保留在磁盘，尚未自动删除或汇总。",
                       "Charts load only the last 35 days. Older records remain on disk; no automatic deletion or rollup is enabled."))
                    .font(.caption).foregroundStyle(.secondary)
                if model.connection != nil {
                    Button(model.verifyingDelivery ? t("正在核验…", "Verifying…") : t("核验云端已上传用量", "Verify uploaded usage")) {
                        Task { await model.verifyCloudDelivery() }
                    }.disabled(model.verifyingDelivery)
                    if let result = model.deliveryVerification {
                        Text(result).font(.caption)
                            .foregroundStyle(model.deliveryVerificationMatches == false ? .orange : .secondary)
                            .textSelection(.enabled)
                        Text(t("核对当前设备已确认时间范围内的记录数和各项 token 总量；不上传本地历史。", "Compares record and token totals in this device’s acknowledged time range; does not upload local history."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let at = model.lastUploadConfirmedAt {
                    Text(t("最近收到上传确认：", "Last upload acknowledged: ") + at.formatted()).font(.caption).foregroundStyle(.secondary)
                }
                if let at = storage.oldestPendingAt.flatMap(UsageTime.parse) {
                    Text(t("最早待上传记录：", "Oldest pending record: ") + at.formatted()).font(.caption).foregroundStyle(.orange)
                }
                if let at = model.nextUploadAttemptAt {
                    Text(at == .distantFuture
                        ? t("上传已暂停：请重新验证设备凭据。", "Uploads paused: verify the device credential again.")
                        : t("下次上传重试：", "Next upload retry: ") + at.formatted())
                        .font(.caption).foregroundStyle(.orange)
                }
            }
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
    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(label).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(.body, design: .rounded, weight: .semibold)).monospacedDigit() }
    }
}
