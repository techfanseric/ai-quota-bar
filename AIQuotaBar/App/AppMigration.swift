import Foundation

enum AppMigration {
    private static let legacyBundleID = "com.minimax.usagemonitor"
    private static let migratedDefaultsKey = "didMigrateDefaultsFromLegacyBundle"

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
}
