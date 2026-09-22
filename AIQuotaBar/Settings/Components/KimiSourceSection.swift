import CodexBarCore
import SwiftUI

@MainActor
struct KimiSourceSection: View {
    let language: AppLanguage
    let onChange: () -> Void
    @AppStorage(KimiDataSourceMode.storageKey) private var mode = KimiDataSourceMode.auto.rawValue
    @AppStorage(KimiDataSourceMode.lastSuccessfulSourceKey) private var lastSource = ""
    @State private var browser = "Chrome"
    @State private var candidates: [Candidate] = []
    @State private var busy = false
    @State private var feedback: String?
    @State private var token = ""
    @State private var origin = "https://www.kimi.com"
    private var chinese: Bool { language == .simplifiedChinese }

    private struct Candidate: Identifiable {
        let id = UUID()
        let label: String
        let session: KimiWebSession
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(mode == KimiDataSourceMode.auto.rawValue
                 ? (chinese ? "自动检测已登录的 Kimi，无需手动选择来源。" : "Automatically detects your Kimi sign-in. No source setup needed.")
                 : (chinese ? "当前已手动指定来源，可在高级选项中恢复自动检测。" : "A source is pinned. Restore automatic detection in advanced options."))
                .font(.callout)
            if !lastSource.isEmpty {
                Text((chinese ? "最近成功读取：" : "Last successful source: ") + lastSource)
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup(chinese ? "高级：来源与登录" : "Advanced: sources and sign-in") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker(chinese ? "额度来源" : "Quota source", selection: $mode) {
                        ForEach(KimiDataSourceMode.allCases) { value in
                            Text(value.title(chinese: chinese)).tag(value.rawValue)
                        }
                    }
                    .onChange(of: mode) { _, _ in
                        feedback = nil
                        candidates = []
                        onChange()
                    }
                    Text(chinese
                         ? "自动使用已保存的 API Key，否则优先读取有效桌面登录，再检查已保存的网页登录、CLI 和可直接读取的浏览器登录。多个网页账号时才需要选择。"
                         : "Auto uses a saved API key, then a valid Desktop sign-in, saved web session, CLI, or accessible browser session. Only multiple web accounts require a choice.")
                        .font(.caption).foregroundStyle(.secondary)

                    if mode == KimiDataSourceMode.desktop.rawValue || mode == KimiDataSourceMode.auto.rawValue {
                        Button(chinese ? "允许读取桌面登录" : "Allow Desktop Access") {
                            busy = true
                            Task {
                                do {
                                    let session = try await Task.detached {
                                        try KimiDesktopSessionReader().load(allowInteraction: true)
                                    }.value
                                    feedback = (chinese ? "已读取：" : "Connected: ") + session.accountLabel
                                    onChange()
                                } catch { feedback = error.localizedDescription }
                                busy = false
                            }
                        }
                        Text(chinese ? "仅在点击时允许系统请求钥匙串授权；后台刷新不会弹出授权窗口。" : "Keychain access may be requested when clicked. Background refresh never prompts.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if mode == KimiDataSourceMode.web.rawValue {
                        HStack {
                            Picker(chinese ? "浏览器" : "Browser", selection: $browser) {
                                ForEach(["Chrome", "Safari", "Edge", "Arc", "Brave"], id: \.self) { Text($0) }
                            }
                            Button(chinese ? "导入登录" : "Import Sign-in", action: importSessions)
                        }
                        Text(chinese ? "导入 kimi.com 登录后选择账号。登录态保存在本机凭据库，过期后重新导入。" : "Import a kimi.com sign-in and select the account. The session stays in the local credential vault; re-import when it expires.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(candidates) { candidate in
                            Button(candidate.label + " · " + candidate.session.accountLabel) {
                                save(candidate.session)
                            }
                        }
                        DisclosureGroup(chinese ? "手动连接网页登录" : "Connect a web session manually") {
                            Picker(chinese ? "站点" : "Site", selection: $origin) {
                                Text("kimi.com").tag("https://www.kimi.com")
                                Text("kimi.ai").tag("https://www.kimi.ai")
                            }
                            SecureField("kimi-auth", text: $token).textFieldStyle(.roundedBorder)
                            Text(chinese ? "填写所选站点的 kimi-auth Cookie 值。" : "Enter the kimi-auth cookie value from the selected site.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button(chinese ? "验证并保存" : "Verify and Save") {
                                save(KimiWebSession(token: token.trimmingCharacters(in: .whitespacesAndNewlines), origin: origin))
                            }.disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        Button(chinese ? "移除网页登录" : "Remove Web Sign-in") {
                            busy = true
                            Task {
                                if await KeychainService.shared.saveDeviceCredential("", binding: KimiService.webSessionBinding) {
                                    feedback = chinese ? "已移除网页登录。" : "Web sign-in removed."
                                    candidates = []; token = ""; onChange()
                                } else { feedback = chinese ? "移除失败。" : "Could not remove sign-in." }
                                busy = false
                            }
                        }
                    }
                }
            }
            if busy { ProgressView().controlSize(.small) }
            if let feedback { Text(feedback).font(.caption).textSelection(.enabled) }
        }
        .disabled(busy)
    }

    private func importSessions() {
        busy = true; feedback = nil; candidates = []
        let selected = browser
        Task {
            do {
                let sessions = try await Task.detached {
                    try ProviderInteractionContext.$current.withValue(.userInitiated) {
                        try BrowserCookieAccessGate.withExplicitRetry {
                            switch selected {
                            case "Safari": return try KimiCookieImporter.importSessions(from: .safari)
                            case "Edge": return try KimiCookieImporter.importSessions(from: .edge)
                            case "Arc": return try KimiCookieImporter.importSessions(from: .arc)
                            case "Brave": return try KimiCookieImporter.importSessions(from: .brave)
                            default: return try KimiCookieImporter.importSessions(from: .chrome)
                            }
                        }
                    }
                }.value
                candidates = sessions.compactMap { entry in
                    guard let cookie = entry.cookies.first(where: {
                        $0.name == "kimi-auth" && ($0.expiresDate == nil || $0.expiresDate! > Date())
                    }), let session = try? KimiWebSession(token: cookie.value, origin: "https://www.kimi.com").validated()
                    else { return nil }
                    return Candidate(label: entry.sourceLabel, session: session)
                }
                if candidates.isEmpty { throw KimiSessionError.noBrowserSession }
                feedback = chinese ? "请选择要连接的账号。" : "Select the account to connect."
            } catch { feedback = error.localizedDescription }
            busy = false
        }
    }

    private func save(_ session: KimiWebSession) {
        busy = true; feedback = nil
        Task {
            do {
                let session = try session.validated()
                _ = try await KimiWebUsageClient().fetch(session)
                let value = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
                guard await KeychainService.shared.saveDeviceCredential(value, binding: KimiService.webSessionBinding) else {
                    throw UsageError.apiError(chinese ? "无法保存网页登录。" : "Could not save web sign-in.")
                }
                feedback = (chinese ? "已连接：" : "Connected: ") + session.accountLabel
                candidates = []; token = ""; onChange()
            } catch { feedback = error.localizedDescription }
            busy = false
        }
    }
}
