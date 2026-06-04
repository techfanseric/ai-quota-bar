import Foundation
import Security

/// Service for secure API key storage using Keychain
final class KeychainService {
    static let shared = KeychainService()

    static let service = "com.techfanseric.aiquotabar"

    /// Keychain `providerCredentials` 条目 decode 失败时发出 ——
    /// 调用方可以选择降级提示用户（"凭据存储损坏"），但不要清空 Keychain。
    static let didFailToDecodeCredentials = Notification.Name("KeychainService.didFailToDecodeCredentials")
    static let credentialsDecodeErrorUserInfoKey = "error"

    private let credentialStoreAccount = "providerCredentials"
    private let cloudSyncTokenKey = "cloudSyncToken"
    private let legacyServices = ["com.minimax.usagemonitor"]
    private var cachedCredentialStore: [String: String]?

    private init() {
        migrateLegacyCloudSyncToken()
    }

    /// Save provider credential to Keychain
    func saveCredential(_ credential: String, for provider: UsageProvider) -> Bool {
        var store = credentialStore()
        store[provider.rawValue] = credential
        return saveCredentialStore(store)
    }

    /// Retrieve provider credential from Keychain
    func getCredential(for provider: UsageProvider) -> String? {
        if let credential = credentialStore()[provider.rawValue] {
            return credential
        }

        if let credential = credential(for: provider, service: Self.service) {
            var store = credentialStore()
            store[provider.rawValue] = credential
            _ = saveCredentialStore(store)
            return credential
        }

        for legacyService in legacyServices {
            if let credential = credential(for: provider, service: legacyService) {
                var store = credentialStore()
                store[provider.rawValue] = credential
                _ = saveCredentialStore(store)
                return credential
            }
        }

        return nil
    }

    private func credential(for provider: UsageProvider, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: provider.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }

        return key
    }

    /// Delete provider credential from Keychain
    @discardableResult
    func deleteCredential(for provider: UsageProvider) -> Bool {
        var store = credentialStore()
        store.removeValue(forKey: provider.rawValue)
        let storeSaved = saveCredentialStore(store)

        let oldItemsDeleted = ([Self.service] + legacyServices).allSatisfy { service in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: provider.keychainAccount
            ]

            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }

        return storeSaved && oldItemsDeleted
    }

    /// Check if provider credential exists
    func hasCredential(for provider: UsageProvider) -> Bool {
        return getCredential(for: provider) != nil
    }

    /// Save MiniMax API key to Keychain
    func saveAPIKey(_ key: String) -> Bool {
        saveCredential(key, for: .miniMax)
    }

    /// Retrieve MiniMax API key from Keychain
    func getAPIKey() -> String? {
        getCredential(for: .miniMax)
    }

    /// Delete MiniMax API key from Keychain
    @discardableResult
    func deleteAPIKey() -> Bool {
        deleteCredential(for: .miniMax)
    }

    /// Check if MiniMax API key exists
    var hasAPIKey: Bool {
        return hasCredential(for: .miniMax)
    }

    func saveCloudSyncToken(_ token: String) -> Bool {
        var store = credentialStore()
        store[cloudSyncTokenKey] = token
        return saveCredentialStore(store)
    }

    func getCloudSyncToken() -> String? {
        credentialStore()[cloudSyncTokenKey]
    }

    @discardableResult
    func deleteCloudSyncToken() -> Bool {
        var store = credentialStore()
        store.removeValue(forKey: cloudSyncTokenKey)
        return saveCredentialStore(store)
    }

    private func migrateLegacyCloudSyncToken() {
        let legacyAccount = "cloudSyncToken"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: legacyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty,
              credentialStore()[cloudSyncTokenKey] == nil else {
            return
        }

        _ = saveCloudSyncToken(token)

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: legacyAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)
    }

    private func credentialStore() -> [String: String] {
        if let cachedCredentialStore {
            return cachedCredentialStore
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: credentialStoreAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            // errSecItemNotFound 是常见路径（首次启动无凭据），无需 cache 或 log。
            // 其他 status（如 errSecAuthFailed / errSecInteractionNotAllowed）也不 cache，
            // 下次调用可以重试，避免误把瞬时错误当永久状态。
            return [:]
        }

        guard let data = result as? Data else {
#if DEBUG
            print("KeychainService.credentialStore: unexpected result type for \(credentialStoreAccount)")
#endif
            return [:]
        }

        do {
            let store = try JSONDecoder().decode([String: String].self, from: data)
            cachedCredentialStore = store
            return store
        } catch {
            // JSON 损坏时 **绝不缓存空 dict** —— 下次 save 会用空 dict 覆盖原始数据，
            // 造成所有 provider 凭据同时丢失。返回空但保留现场，等用户或迁移逻辑介入。
#if DEBUG
            print("KeychainService.credentialStore: failed to decode \(credentialStoreAccount): \(error.localizedDescription)")
#endif
            NotificationCenter.default.post(
                name: Self.didFailToDecodeCredentials,
                object: nil,
                userInfo: [Self.credentialsDecodeErrorUserInfoKey: error]
            )
            return [:]
        }
    }

    private func saveCredentialStore(_ store: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(store) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: credentialStoreAccount
        ]

        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            cachedCredentialStore = store
            return true
        }

        guard updateStatus == errSecItemNotFound else { return false }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { return false }

        cachedCredentialStore = store
        return true
    }

    private func saveGenericSecret(_ secret: String, account: String) -> Bool {
        guard let data = secret.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]

        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        guard updateStatus == errSecItemNotFound else { return false }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    private func getGenericSecret(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private func deleteGenericSecret(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
