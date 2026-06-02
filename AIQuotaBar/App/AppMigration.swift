import Foundation
import Security

enum AppMigration {
    private static let legacyBundleID = "com.minimax.usagemonitor"
    private static let migratedDefaultsKey = "didMigrateDefaultsFromLegacyBundle"
    private static let codexMigrationKey = "codexMigration_v1"
    private static let keychainService = "com.techfanseric.aiquotabar"
    private static let legacyChatGPTCredentialAccount = "chatGPTCredential"

    static func migrateLegacyDefaultsIfNeeded() {
        let currentDefaults = UserDefaults.standard
        guard currentDefaults.bool(forKey: migratedDefaultsKey) == false,
              let legacyDefaults = UserDefaults(suiteName: legacyBundleID) else {
            return
        }

        for key in [
            "refreshInterval",
            "displayFormat",
            "warningThreshold",
            "selectedModelName",
            "autoRefreshOnLaunch",
            AppLanguage.storageKey
        ] where currentDefaults.object(forKey: key) == nil {
            if let value = legacyDefaults.object(forKey: key) {
                currentDefaults.set(value, forKey: key)
            }
        }

        currentDefaults.set(true, forKey: migratedDefaultsKey)
    }

    static func runCodexMigrationIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: codexMigrationKey) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: legacyChatGPTCredentialAccount
        ]
        _ = SecItemDelete(query as CFDictionary)

        if let oldProvider = defaults.string(forKey: "usageProvider"),
           oldProvider == "chatgpt" {
            defaults.set("codex", forKey: "usageProvider")
        }

        defaults.set(true, forKey: codexMigrationKey)
    }
}
