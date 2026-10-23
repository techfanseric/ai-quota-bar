import Foundation
import CodexLocalUsageCore

/// auth.json 的守护镜像：一份独立于 ~/.codex 的凭据副本库。
///
/// ## 为什么需要它
///
/// `~/.codex/auth.json` 不是只有 Codex 会写：
///
/// - **magpie 这类 LLM 网关**每 5 分钟检查一次，当前账号额度见底就把登录切到
///   别的账号；刷新 token 后也会把旋转后的凭据回写同一个文件。
/// - **codexbar 等切换器**也会改写它。
///
/// 无论哪一种，被换走的那个账号的凭据都会从 auth.json 上消失。如果本机没有
/// 另一份副本，那个账号在文件层面就等于丢了——它并没有被 OpenAI 注销，
/// 而是没人再持有那串能用的凭据。
///
/// ## 它保证什么
///
/// 一条不变式：**任何时刻，任何本机见过的 Codex 账号，都至少有一份凭据副本
/// 存在于 ~/.codex 之外。**
///
/// ## 它不做什么
///
/// 镜像只跟随，绝不参与切换：
///
/// - 跟随 auth.json 当前内容（换账号、token 刷新都同步）；
/// - 跟随账号池里每个文件的当前内容（池文件被误删也能从镜像找回）；
/// - 绝不被切换逻辑读走或移动——切换仍然只在 auth.json 与账号池之间发生。
///
/// 路径：~/Library/Application Support/com.techfanseric.aiquotabar/codex-auth-mirror/<digest>.json
/// 权限 0600，与 ~/.codex/accounts/ 下的凭据文件一致。
@MainActor
final class CodexAuthMirror {
    static let shared = CodexAuthMirror()

    /// 一次同步的结论。
    enum SyncResult: Equatable {
        /// 与上次观察一致，没有内容变化。
        case unchanged
        /// 同一个账号，凭据内容变了（token 被刷新）——副本已同步。
        case tokenRefreshed(String)
        /// 换成了另一个账号——副本已同步。带上被换走的那个账号的邮箱。
        case accountChanged(digest: String, previousEmail: String?)
        /// auth.json 读不出来（不存在、损坏、或不是登录态）。
        case unreadable
    }

    private let directory: URL
    private let fileManager: FileManager

    /// 上一次观察到的 auth.json 账号指纹与版本号，用来区分
    /// 「换了账号」和「同一账号换了 token」。
    private var lastDigest: String?
    private var lastGeneration: String?
    /// 上一次观察到的账号邮箱；换账号时用来报出「被换走的是谁」。
    private var lastEmail: String?
    /// 已见过的账号指纹 → 邮箱。
    private(set) var knownEmails: [String: String] = [:]

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            let appSupport = fileManager.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
            self.directory = appSupport
                .appendingPathComponent("com.techfanseric.aiquotabar", isDirectory: true)
                .appendingPathComponent("codex-auth-mirror", isDirectory: true)
        }
    }

    /// 镜像目录（目录本身在真正写入时才创建）。
    var directoryURL: URL { directory }

    func mirrorURL(for digest: String) -> URL {
        directory.appendingPathComponent(digest + ".json")
    }

    /// 当前镜像里已保存的账号指纹。
    func mirroredDigests() -> Set<String> {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: []) else { return [] }
        return Set(entries.compactMap { url -> String? in
            guard url.pathExtension == "json" else { return nil }
            return url.deletingPathExtension().lastPathComponent
        })
    }

    /// 同步 auth.json 与账号池里的全部凭据内容。
    ///
    /// 内容没变时不动文件——这个方法会被 5 秒一次的展示期轮询高频调用。
    @discardableResult
    func sync(authURL: URL, accountsDirectory: URL) -> SyncResult {
        // 账号池里的每个备份也留一份镜像：池文件被误删时还能从镜像找回。
        for url in credentialFiles(in: accountsDirectory) {
            guard let credential = CodexAuthFileReader.readCredential(at: url),
                  case let .chatgptLogin(login) = credential.status else { continue }
            store(credential, digest: login.accountDigest)
        }

        guard let credential = CodexAuthFileReader.readCredential(at: authURL),
              case let .chatgptLogin(login) = credential.status else {
            return .unreadable
        }

        let digest = login.accountDigest
        store(credential, digest: digest)
        knownEmails[digest] = login.email

        let result: SyncResult
        if let last = lastDigest, last != digest {
            result = .accountChanged(digest: digest, previousEmail: lastEmail)
        } else if let generation = lastGeneration, generation != credential.generation {
            result = .tokenRefreshed(digest)
        } else {
            result = .unchanged
        }
        lastDigest = digest
        lastEmail = login.email
        lastGeneration = credential.generation
        return result
    }

    /// 某个账号指纹对应的邮箱。
    func email(for digest: String) -> String? {
        knownEmails[digest]
    }

    /// 记下一个由本应用自己发起的账号变动。
    ///
    /// 下一次观察到同一个账号指纹时，不再把它算成「外部工具切了账号」。
    /// generation 一并清掉：切换是一次整体替换，不是同账号的 token 刷新。
    func acknowledgeLocalChange(digest: String, email: String?) {
        lastDigest = digest
        lastEmail = email
        lastGeneration = nil
        knownEmails[digest] = email
    }

    // MARK: - 写盘

    private func store(_ credential: CodexAuthCredential, digest: String) {
        let url = mirrorURL(for: digest)
        if let existing = try? Data(contentsOf: url), existing == credential.data {
            return
        }
        do {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true)
            // 目录与文件都锁成仅本人可读写：里面是可直接使用的凭据。
            try fileManager.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try credential.data.write(to: url, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            #if DEBUG
            print("CodexAuthMirror store failed: \(error.localizedDescription)")
            #endif
        }
    }

    private func credentialFiles(in accountsDirectory: URL) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: accountsDirectory, includingPropertiesForKeys: nil, options: []) else { return [] }
        return entries.filter {
            $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".")
        }
    }
}
