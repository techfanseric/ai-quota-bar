import AppKit
import SwiftUI
import CodexLocalUsageCore

@MainActor
struct TeamSettingsSection: View {
    @Bindable var viewModel: UsageViewModel
    @Bindable var model: CodexLocalUsageModel
    @State private var creating = false
    @State private var teamName = ""
    @State private var name = ""
    @State private var invite = ""
    @State private var passphrase = ""
    @State private var includeHistory = false
    @State private var busy = false
    @State private var confirmLeave = false
    private func t(_ zh: String, _ en: String) -> String { viewModel.appLanguage == .simplifiedChinese ? zh : en }

    var body: some View {
        SettingsSection(title: t("团队", "Team"), contentSpacing: 12) {
            if let connection = model.connection {
                HStack {
                    Image(systemName: "person.2.fill").foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text(connection.identity.team_name ?? connection.identity.team_id).font(.headline)
                        Text(connection.identity.member_name).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(t("管理团队…", "Manage team…")) {
                        if let url = URL(string: connection.endpoint + "/team") { NSWorkspace.shared.open(url) }
                    }
                    Button(t("退出团队", "Leave team"), role: .destructive) { confirmLeave = true }
                        .disabled(busy || model.syncing || model.connectingTeam)
                }
                Toggle(t("共享本机用量", "Share local usage"), isOn: $model.reportingEnabled).toggleStyle(.checkbox)
                Toggle(t("共享账号额度", "Share account quota"), isOn: $viewModel.cloudSyncEnabled).toggleStyle(.checkbox)
                Text(t("仅在当前团队内共享统计，不同步供应商登录凭据。团队管理需要创建时获得的管理密码。", "Statistics stay within this team. Provider login credentials are never synced. Team management requires the team's management password."))
                    .font(.caption).foregroundStyle(.secondary)
                teamSummary
                DisclosureGroup(t("同步状态与日志", "Sync status & log")) {
                    VStack(alignment: .leading, spacing: 8) {
                        CloudSyncStatusLine(status: viewModel.cloudSyncStatus, language: viewModel.appLanguage)
                        if !model.syncStatus.isEmpty { Text(model.syncStatus).font(.caption) }
                        Text(t("上报起点：", "Reporting begins: ") + connection.since.formatted()).font(.caption)
                        Button(t("立即同步", "Sync now")) {
                            Task { await model.refresh(); await CloudSyncService.shared.flushPendingQueue(); await viewModel.reloadCloudUsageData() }
                        }.disabled(model.syncing)
                        ForEach(CloudDiagnosticLog.shared.entries.prefix(10)) { entry in
                            Text(entry.date.formatted(date: .omitted, time: .shortened) + " · " + entry.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.top, 8)
                }
                DisclosureGroup(t("连接另一台 Mac", "Connect another Mac")) {
                    SecureField(t("成员口令（至少 4 位）", "Member passphrase (at least 4 characters)"), text: $passphrase)
                    Button(t("保存成员口令", "Save member passphrase")) {
                        Task { await model.setMemberPassphrase(passphrase); if model.error == nil { passphrase = "" } }
                    }.disabled(passphrase.count < 4)
                    Text(t("另一台 Mac 使用同一邀请码、名字和成员口令加入。", "Join from the other Mac using the same invite code, name and member passphrase.")).font(.caption)
                }
            } else {
                Text(t("个人使用无需建团。想按成员、账号和设备统管用量，可以创建团队或加入已有团队。", "Personal usage works without a team. Create or join a team to see usage by member, account and device."))
                    .font(.callout).foregroundStyle(.secondary)
                Picker(t("开始使用", "Get started"), selection: $creating) {
                    Text(t("加入团队", "Join team")).tag(false)
                    Text(t("创建团队", "Create team")).tag(true)
                }.pickerStyle(.segmented).disabled(model.createdTeam != nil)
                if creating { TextField(t("团队名称", "Team name"), text: $teamName) }
                else { TextField(t("邀请码", "Invite code"), text: $invite) }
                TextField(t("你的名字", "Your name"), text: $name)
                SecureField(t("成员口令（至少 4 位，连接多台 Mac 时使用）", "Member passphrase (4+ characters, for multiple Macs)"), text: $passphrase)
                Toggle(t("同时上报尚未归属团队的本机历史", "Also share unassigned local history"), isOn: $includeHistory).toggleStyle(.checkbox)
                Text(t("默认从加入时开始共享本机消耗和账号额度，可随时分别暂停。", "By default, sharing starts when you join. Local usage and account quota can each be paused."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(creating ? t("创建并加入", "Create & join") : t("加入团队", "Join team")) {
                        busy = true
                        Task {
                            if creating { await model.createTeam(name: teamName, memberName: name, passphrase: passphrase, includeHistory: includeHistory) }
                            else { await model.joinTeam(inviteCode: invite, memberName: name, passphrase: passphrase, endpoint: nil, includeHistory: includeHistory) }
                            if model.error == nil { invite = ""; passphrase = ""; viewModel.cloudSyncEnabled = true }
                            busy = false
                        }
                    }.buttonStyle(.borderedProminent)
                        .disabled(busy || model.syncing || name.trimmingCharacters(in: .whitespaces).isEmpty || (creating ? teamName : invite).trimmingCharacters(in: .whitespaces).isEmpty || passphrase.count < 4)
                    if busy { ProgressView().controlSize(.small) }
                }
            }
            if let created = model.createdTeam {
                VStack(alignment: .leading, spacing: 6) {
                    Text(t("保存团队信息", "Save team details")).font(.headline)
                    Text(t("邀请码可分享给成员；管理密码仅交给团队管理者。以下信息只在本次创建后显示。", "Share the invite with members. Keep the management password with team managers. These details are shown only after creation."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text("ID: " + created.teamID).textSelection(.enabled)
                    Text(t("邀请码：", "Invite: ") + created.inviteCode).textSelection(.enabled)
                    Text(t("管理密码：", "Management password: ") + created.loginPassword).textSelection(.enabled)
                    Button(t("复制团队信息", "Copy team details")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\(created.teamName)\nID: \(created.teamID)\nInvite: \(created.inviteCode)\nPassword: \(created.loginPassword)", forType: .string)
                    }
                    if model.connection != nil { Button(t("已保存", "Saved")) { model.createdTeam = nil } }
                }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .confirmationDialog(t("退出当前团队？", "Leave this team?"), isPresented: $confirmLeave) {
            Button(t("退出团队", "Leave team"), role: .destructive) {
                viewModel.cloudSyncEnabled = false
                model.reportingEnabled = false
                Task { await model.leaveTeam() }
            }
        } message: { Text(t("停止本机上报并撤销设备凭据。团队历史与本机数据保留。", "Stop reporting and revoke this device's credential. Team history and local data are retained.")) }
    }

    private var teamSummary: some View {
        DisclosureGroup(t("团队用量", "Team usage")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker(t("时间范围", "Range"), selection: $model.days) {
                        Text(t("近 7 天", "7 days")).tag(7)
                        Text(t("近 30 天", "30 days")).tag(30)
                        Text(t("近 90 天", "90 days")).tag(90)
                    }.frame(maxWidth: 220)
                    Button(t("刷新", "Refresh")) { Task { await model.loadTeam() } }
                }
                ForEach(model.teamRows) { row in
                    DisclosureGroup {
                        ForEach(model.teamDevices.filter { $0.memberID == row.id }) { device in
                            HStack { Text(String(device.name.prefix(12))); Spacer(); Text((device.input + device.output).formatted() + " tokens") }.font(.caption)
                        }
                    } label: {
                        HStack { Text(row.name); Spacer(); Text((row.input + row.output).formatted() + " tokens").monospacedDigit() }
                    }
                }
                if model.teamRows.isEmpty { Text(t("暂无团队用量，点击刷新加载。", "No team usage loaded. Refresh to load.")).font(.caption).foregroundStyle(.secondary) }
                ForEach(model.teamAccounts) { row in
                    HStack {
                        Text(row.id == "unknown" ? t("未知账号", "Unknown account") : String(row.id.prefix(12)))
                        Spacer(); Text((row.input + row.output).formatted() + " tokens")
                    }.font(.caption)
                }
                Text(t("账号额度显示在菜单中；成员消耗单独统计，不按设备重复累加共享额度。", "Account quota appears in the menu. Member consumption is tracked separately; shared quota is not summed across devices."))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 8)
        }.onChange(of: model.days) { _, _ in model.teamRows = []; model.teamDevices = []; model.teamAccounts = []; Task { await model.loadTeam() } }
    }
}
