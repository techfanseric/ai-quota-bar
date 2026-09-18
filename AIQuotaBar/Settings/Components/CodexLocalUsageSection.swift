import SwiftUI
import UniformTypeIdentifiers
import CodexLocalUsageCore

@MainActor
struct CodexLocalUsageSection: View {
    @Bindable var model: CodexLocalUsageModel
    let language: AppLanguage
    @State private var inviteCode = ""
    @State private var memberName = ""
    @State private var passphrase = ""
    @State private var newPassphrase = ""
    @State private var advancedEndpoint = ""
    @State private var token = ""
    @State private var includeHistory = false
    @State private var importing = false
    @State private var connecting = false
    @State private var savingPassphrase = false
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
            DisclosureGroup(t("成员归属与上报", "Member identity & reporting")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(t("设备 ID：", "Device ID: ") + model.deviceID).font(.caption).textSelection(.enabled)
                    if model.connection == nil {
                        Text(t("队长在官网 /team 页面创建团队，把邀请码发给每位成员；在这里填入邀请码和你的名字即可加入。", "The team owner creates a team on the /team page and shares the invite code; enter it here with your name to join."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField(t("邀请码", "Invite code"), text: $inviteCode)
                    TextField(t("你的名字（团队统计中显示）", "Your name (shown in team stats)"), text: $memberName)
                    SecureField(t("成员口令（可选；第二台 Mac 用同一名字加入时需要）", "Member passphrase (optional; needed to join a second Mac under the same name)"), text: $passphrase)
                    Toggle(t("将尚未分配的本机历史归属此成员", "Assign unassigned local history to this member"), isOn: $includeHistory)
                        .toggleStyle(.checkbox)
                    Button(t("加入团队", "Join team")) {
                        connecting = true
                        Task {
                            await model.joinTeam(inviteCode: inviteCode, memberName: memberName, passphrase: passphrase,
                                                 endpoint: advancedEndpoint.isEmpty ? nil : advancedEndpoint, includeHistory: includeHistory)
                            if model.error == nil { inviteCode = ""; passphrase = "" }
                            connecting = false
                        }
                    }.disabled(connecting || model.syncing || inviteCode.trimmingCharacters(in: .whitespaces).isEmpty || memberName.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let connection = model.connection {
                        Text("\(connection.identity.member_name) · \(connection.identity.team_id)")
                        Text(t("上报起点：", "Reporting begins: ") + connection.since.formatted()).font(.caption)
                        SecureField(t("设置成员口令（第二台 Mac 加入时使用）", "Set member passphrase (for joining a second Mac)"), text: $newPassphrase)
                        Button(t("保存成员口令", "Save member passphrase")) {
                            savingPassphrase = true
                            Task {
                                await model.setMemberPassphrase(newPassphrase)
                                if model.error == nil { newPassphrase = "" }
                                savingPassphrase = false
                            }
                        }.disabled(savingPassphrase || newPassphrase.count < 4)
                    }
                    DisclosureGroup(t("高级：私有部署与管理员签发凭据", "Advanced: private deployment & admin-issued credential")) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField(t("团队服务器地址（HTTPS，留空使用公共云端）", "Team server origin (HTTPS; empty uses the public cloud)"), text: $advancedEndpoint)
                            SecureField(t("管理员为此设备签发的凭据", "Device credential issued by your administrator"), text: $token)
                            Button(t("验证并绑定设备", "Verify and bind device")) {
                                connecting = true
                                Task {
                                    await model.connect(endpoint: advancedEndpoint, token: token, includeHistory: includeHistory)
                                    if model.error == nil { token = "" }
                                    connecting = false
                                }
                            }.disabled(connecting || model.syncing || advancedEndpoint.isEmpty || token.isEmpty)
                        }.padding(.top, 4)
                    }
                    Text(t("仅上报时间、模型、token 数和不透明事件标识，不上传对话、代码、路径或 OpenAI 凭据。成员切换不会改写已归属的历史。", "Reports only timestamps, models, token counts and opaque event IDs. No conversations, code, paths or OpenAI credentials. Switching members does not reassign history."))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(t("启用成员用量上报", "Enable member usage reporting"), isOn: $model.reportingEnabled)
                        .disabled(model.connection == nil).toggleStyle(.checkbox)
                    if !model.syncStatus.isEmpty { Text(model.syncStatus).font(.caption).textSelection(.enabled) }
                    ForEach(model.rejectionReasons.keys.sorted(), id: \.self) { reason in
                        Text("\(reason): \(model.rejectionReasons[reason, default: 0])").font(.caption).foregroundStyle(.orange)
                    }
                }.padding(.top, 8)
            }
            if model.connection != nil {
                DisclosureGroup(t("团队成员用量", "Team member usage")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button(t("加载近 30 天", "Load last 30 days")) { Task { await model.loadTeam() } }
                        ForEach(model.teamRows) { row in
                            DisclosureGroup {
                                ForEach(model.teamDevices.filter { $0.memberID == row.id }) { device in
                                    teamLine(device)
                                }
                            } label: { teamLine(row) }
                        }
                        if !model.teamAccounts.isEmpty {
                            Divider()
                            Text(t("团队账号汇总（含本机观测归属）", "Team accounts (includes login observations)")).font(.caption.weight(.semibold))
                            ForEach(model.teamAccounts) { row in
                                HStack {
                                    Text(row.id == "unknown" ? t("账号未知", "Unknown account") : (model.accountLabels[row.id] ?? String(row.id.prefix(10))))
                                    Spacer()
                                    Text((row.input + row.output).formatted() + " tokens")
                                }.font(.caption)
                            }
                        }
                        if model.teamRows.isEmpty { Text(t("点击加载，查看团队统计。", "Load to view team usage.")).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.top, 8)
                }
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .onAppear { advancedEndpoint = model.connection?.endpoint ?? ""; model.days = 30 }
        .onChange(of: model.days) { _, _ in model.teamRows = []; model.teamDevices = []; model.teamAccounts = [] }
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(label).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(.body, design: .rounded, weight: .semibold)).monospacedDigit() }
    }
    private func teamLine(_ row: TeamUsageRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Text(row.name).lineLimit(1); Spacer(); Text((row.input + row.output).formatted() + " tokens").monospacedDigit() }
            Text(t("\(row.records) 条 · 缓存 ", "\(row.records) records · Cache ") + (row.cacheHitRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—")
                + (row.pricedRecords > 0 ? String(format: " · $%.4f", row.costUSD) : t(" · 未定价", " · Unpriced"))
                + " (\(row.pricedRecords)/\(row.records))").foregroundStyle(.secondary)
        }.font(.caption)
    }
}
