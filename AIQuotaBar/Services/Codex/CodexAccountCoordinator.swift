import CodexBarCore
import Foundation

/// 账号列表摘要：给 Settings 面板渲染用。
struct CodexAccountDraft: Identifiable, Equatable {
    let id: String
    let name: String
    let email: String
    let planType: String
    let sourceLabel: String
    let lastRefresh: Date?
    let isActive: Bool
}

/// 协调 codexbar 的 FileManagedCodexAccountStore，
/// 为 Settings 面板的账号列表提供数据。
final class CodexAccountCoordinator {
    static let shared = CodexAccountCoordinator()

    private let store: FileManagedCodexAccountStore

    private init() {
        self.store = FileManagedCodexAccountStore()
    }

    /// 读取当前所有 stored accounts 的摘要，用于 Settings 列表渲染
    func listAccountDrafts() -> [CodexAccountDraft] {
        do {
            let set = try store.loadAccounts()
            return set.accounts.map { account in
                CodexAccountDraft(
                    id: account.id.uuidString,
                    name: account.workspaceLabel ?? account.email,
                    email: account.email,
                    planType: "",
                    sourceLabel: sourceLabel(for: account),
                    lastRefresh: account.lastAuthenticatedAt.map {
                        Date(timeIntervalSince1970: $0)
                    },
                    isActive: false)
            }
        } catch {
            return []
        }
    }

    var hasManagedAccount: Bool {
        !listAccountDrafts().isEmpty
    }

    /// 删除指定账号（仅从 managed 列表中移除；auth 文件保留以便回退）
    func removeAccount(id: String) {
        guard let uuid = UUID(uuidString: id) else { return }
        do {
            let set = try store.loadAccounts()
            let remaining = set.accounts.filter { $0.id != uuid }
            try store.storeAccounts(ManagedCodexAccountSet(
                version: FileManagedCodexAccountStore.currentVersion,
                accounts: remaining))
        } catch {
            // 静默失败；UI 已显示删除意图
        }
    }

    /// 清空所有账号
    func removeAll() {
        do {
            try store.storeAccounts(ManagedCodexAccountSet(
                version: FileManagedCodexAccountStore.currentVersion,
                accounts: []))
        } catch {
            // 静默失败
        }
    }

    private func sourceLabel(for account: ManagedCodexAccount) -> String {
        let hasAuth = CodexAuthFingerprint.fingerprint(
            homePath: account.managedHomePath) != nil
        return hasAuth ? "OAuth" : "Unknown"
    }
}
