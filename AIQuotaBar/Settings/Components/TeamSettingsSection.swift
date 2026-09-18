import AppKit
import SwiftUI
import CodexLocalUsageCore

@MainActor
struct TeamSettingsSection: View {
    @Bindable var viewModel: UsageViewModel
    @Bindable var model: CodexLocalUsageModel
    @State private var creating = true
    @State private var teamName = ""
    @State private var name = ""
    @State private var invite = ""
    @State private var passphrase = ""
    @State private var includeHistory = false
    @State private var busy = false
    @State private var confirmLeave = false
    @State private var switchingTeam = false
    @State private var showingManagement = false
    @State private var managementPassword = ""
    @State private var browserBusy = false
    @State private var browserError: String?
    @State private var summaryExpanded = true
    @State private var formError: String?
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
                    Button(t("查看团队 ↗", "View team ↗")) { openTeam(manage: false) }
                        .disabled(browserBusy || model.connectingTeam)
                    Button(t("管理团队…", "Manage team…")) {
                        if model.canManageTeam { openTeam(manage: true) }
                        else { showingManagement = true; browserError = nil }
                    }.disabled(browserBusy || model.connectingTeam)
                    Button(t("退出团队", "Leave team"), role: .destructive) { confirmLeave = true }
                        .disabled(busy || model.syncing || model.connectingTeam)
                }
                Toggle(t("共享本机用量", "Share local usage"), isOn: $model.reportingEnabled).toggleStyle(.checkbox)
                Toggle(t("共享账号额度", "Share account quota"), isOn: $viewModel.cloudSyncEnabled).toggleStyle(.checkbox)
                Text(t("所有团队成员都能查看本团队的成员、设备和账号用量；仅管理者能更新邀请码和移除成员。供应商登录凭据不会共享。", "All members can view this team's member, device and account usage. Only managers can rotate invitations and remove members. Provider login credentials are never shared."))
                    .font(.caption).foregroundStyle(.secondary)
                teamSummary
                Button(t("创建或加入其他团队…", "Create or join another team…")) {
                    if model.createdTeam?.teamID == connection.identity.team_id { model.createdTeam = nil }
                    name = connection.identity.member_name; switchingTeam = true
                }.disabled(busy || model.syncing || model.connectingTeam)
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
                onboardingForm
            }
            recoveryDetails
            if browserBusy { ProgressView().controlSize(.small) }
            if let browserError { Text(browserError).font(.caption).foregroundStyle(.red) }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .task(id: model.connection?.binding) {
            await model.refreshManagementAccess()
            if model.connection != nil { await model.loadTeam() }
        }
        .sheet(isPresented: $switchingTeam) {
            VStack(alignment: .leading, spacing: 14) {
                Text(t("创建或加入其他团队", "Create or join another team")).font(.title2)
                Text(t("成功后本机将切换团队，旧团队历史保留。已归属旧团队的用量不会转移。", "This Mac switches teams after success. Previous team history stays there; assigned usage is never transferred."))
                    .font(.callout).foregroundStyle(.secondary)
                onboardingForm
                recoveryDetails
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
                Button(t("取消", "Cancel")) { switchingTeam = false }.disabled(busy)
            }.padding(24).frame(width: 520).interactiveDismissDisabled(busy)
        }
        .sheet(isPresented: $showingManagement) {
            VStack(alignment: .leading, spacing: 14) {
                Text(t("连接团队管理", "Connect team management")).font(.title2)
                Text(t("仅首次需要管理密码。验证后保存在本机钥匙串，以后可直接进入。普通成员无需密码，点击“查看团队”即可。", "Enter the management password once. After verification it is saved in this Mac's Keychain for direct access. Members can use View team without a password."))
                    .font(.callout).foregroundStyle(.secondary)
                SecureField(t("团队管理密码", "Team management password"), text: $managementPassword)
                if let browserError { Text(browserError).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button(t("取消", "Cancel")) { showingManagement = false; managementPassword = "" }.disabled(browserBusy)
                    Spacer()
                    Button(t("验证并打开", "Verify & open")) { openTeam(manage: true, password: managementPassword) }
                        .buttonStyle(.borderedProminent).disabled(browserBusy || managementPassword.isEmpty)
                }
            }.padding(24).frame(width: 460).interactiveDismissDisabled(browserBusy)
        }
        .confirmationDialog(t("退出当前团队？", "Leave this team?"), isPresented: $confirmLeave) {
            Button(t("退出团队", "Leave team"), role: .destructive) {
                viewModel.cloudSyncEnabled = false
                model.reportingEnabled = false
                Task { await model.leaveTeam() }
            }
        } message: { Text(t("停止本机上报并撤销设备凭据。团队历史与本机数据保留。", "Stop reporting and revoke this device's credential. Team history and local data are retained.")) }
    }


    private func openTeam(manage: Bool, password: String? = nil) {
        browserBusy = true; browserError = nil
        Task {
            defer { browserBusy = false }
            do {
                let url = try await model.teamBrowserURL(manage: manage, password: password)
                guard NSWorkspace.shared.open(url) else { throw UsageFailure.invalid(t("无法打开浏览器，请重试。", "Could not open the browser. Please retry.")) }
                managementPassword = ""; showingManagement = false
            } catch {
                browserError = error.localizedDescription.contains("401")
                    ? t("管理密码不正确或设备授权已失效。请重新输入管理密码；成员访问失败时请重新加入团队。", "The management password is incorrect or device access has expired. Re-enter the password; if member access fails, rejoin the team.")
                    : error.localizedDescription
                if manage && !model.canManageTeam { showingManagement = true }
            }
        }
    }
    @ViewBuilder private var onboardingForm: some View {
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
                    Button(creating ? (switchingTeam ? t("创建并切换", "Create & switch") : t("创建并加入", "Create & join")) : (switchingTeam ? t("加入并切换", "Join & switch") : t("加入团队", "Join team"))) {
                        busy = true; formError = nil
                        Task {
                            let success: Bool
                            if creating { success = await model.createTeam(name: teamName, memberName: name, passphrase: passphrase, includeHistory: includeHistory) }
                            else { success = await model.joinTeam(inviteCode: invite, memberName: name, passphrase: passphrase, endpoint: nil, includeHistory: includeHistory) }
                            if success { invite = ""; passphrase = ""; viewModel.cloudSyncEnabled = true; switchingTeam = false; await model.refreshManagementAccess() }
                            else { formError = model.error ?? t("暂时无法连接团队，请稍后重试。", "Could not connect to the team. Please retry.") }
                            busy = false
                        }
                    }.buttonStyle(.borderedProminent)
                        .disabled(busy || model.connectingTeam || model.syncing || name.trimmingCharacters(in: .whitespaces).isEmpty || (creating ? teamName : invite).trimmingCharacters(in: .whitespaces).isEmpty || passphrase.count < 4)
                    if busy { ProgressView().controlSize(.small) }
                }
                if let formError { Text(formError).font(.caption).foregroundStyle(.red) }
    }
    @ViewBuilder private var recoveryDetails: some View {
            if let created = model.createdTeam {
                VStack(alignment: .leading, spacing: 6) {
                    Text(t("保存团队信息", "Save team details")).font(.headline)
                    Text(t("邀请码可分享给成员；管理密码仅交给团队管理者。请另存备份；创建成功后会将管理密码保存在本机钥匙串。", "Share the invite with members. Keep the management password with team managers. Keep a backup; successful creation saves the management password in this Mac's Keychain."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text("ID: " + created.teamID).textSelection(.enabled)
                    Text(t("邀请码：", "Invite: ") + created.inviteCode).textSelection(.enabled)
                    Text(t("管理密码：", "Management password: ") + created.loginPassword).textSelection(.enabled)
                    Button(t("复制团队信息", "Copy team details")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\(created.teamName)\nID: \(created.teamID)\nInvite: \(created.inviteCode)\nPassword: \(created.loginPassword)", forType: .string)
                    }
                    if model.connection?.identity.team_id == created.teamID { Button(t("已保存", "Saved")) { model.createdTeam = nil } }
                }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

    }

    private var teamSummary: some View {
        DisclosureGroup(t("团队用量", "Team usage"), isExpanded: $summaryExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker(t("时间范围", "Range"), selection: $model.days) {
                        Text(t("近 7 天", "7 days")).tag(7)
                        Text(t("近 30 天", "30 days")).tag(30)
                        Text(t("近 90 天", "90 days")).tag(90)
                    }.frame(maxWidth: 220)
                    Button(t("刷新", "Refresh")) { Task { await model.loadTeam() } }.disabled(model.teamLoading)
                    if model.teamLoading { ProgressView().controlSize(.small) }
                }
                ForEach(model.teamRows) { row in
                    DisclosureGroup {
                        ForEach(model.teamDevices.filter { $0.memberID == row.id }) { device in
                            HStack { Text(String(device.name.prefix(12))); Spacer(); Text((device.input + device.output).formatted() + " tokens") }.font(.caption)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text(row.name); Spacer(); Text((row.input + row.output).formatted() + " tokens").monospacedDigit() }
                            Text(rowDetails(row)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = model.teamLoadError { Text(error).font(.caption).foregroundStyle(.red) }
                if let updated = model.teamUpdatedAt { Text(t("更新于 ", "Updated ") + updated.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                if model.teamRows.isEmpty && !model.teamLoading && model.teamLoadError == nil {
                    Text(t("此时间段暂无上报。成员开启“共享本机用量”后会自动显示。", "No reports in this period. Usage appears after members enable Share local usage.")).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.teamAccounts) { row in
                    HStack {
                        Text(row.id == "unknown" ? t("未知账号", "Unknown account") : String(row.id.prefix(12)))
                        Spacer(); Text((row.input + row.output).formatted() + " tokens")
                    }.font(.caption)
                }
                Text(t("账号额度显示在菜单中；成员消耗单独统计，不按设备重复累加共享额度。", "Account quota appears in the menu. Member consumption is tracked separately; shared quota is not summed across devices."))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 8)
        }.onChange(of: model.days) { _, _ in model.clearTeamSummary(); Task { await model.loadTeam() } }
    }
    private func rowDetails(_ row: TeamUsageRow) -> String {
        let cache = row.cacheHitRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—"
        let cost = row.pricedRecords > 0 ? String(format: "$%.4f", row.costUSD) : t("未定价", "Unpriced")
        return "\(row.records) " + t("条记录 · 缓存 ", "records · Cache ") + cache + " · " + cost
    }

}
