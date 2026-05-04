import Foundation
import Security

/// Service for secure API key storage using Keychain
final class KeychainService {
    static let shared = KeychainService()

    private let service = "com.techfanseric.aiquotabar"
    private let credentialStoreAccount = "providerCredentials"
    private let legacyServices = ["com.minimax.usagemonitor"]
    private var cachedCredentialStore: [String: String]?

    private init() {}

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

        if let credential = credential(for: provider, service: service) {
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
            kSecAttrService as String: service,
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

        let oldItemsDeleted = ([service] + legacyServices).allSatisfy { service in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
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

    private func credentialStore() -> [String: String] {
        if let cachedCredentialStore {
            return cachedCredentialStore
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialStoreAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let store = try? JSONDecoder().decode([String: String].self, from: data) else {
            cachedCredentialStore = [:]
            return [:]
        }

        cachedCredentialStore = store
        return store
    }

    private func saveCredentialStore(_ store: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(store) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
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
}
