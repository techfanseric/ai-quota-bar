import Foundation
import Security

/// Service for secure API key storage using Keychain
final class KeychainService {
    static let shared = KeychainService()

    private let service = "com.minimax.usagemonitor"

    private init() {}

    /// Save provider credential to Keychain
    func saveCredential(_ credential: String, for provider: UsageProvider) -> Bool {
        guard let data = credential.data(using: .utf8) else { return false }

        deleteCredential(for: provider)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Retrieve provider credential from Keychain
    func getCredential(for provider: UsageProvider) -> String? {
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.keychainAccount
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
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
}
