import Foundation
import Security

enum MobileDashboardAccessTokenLoadResult: Sendable, Equatable {
    case found(String)
    case notFound
    case failure(OSStatus)
}

protocol MobileDashboardAccessTokenStoring: Sendable {
    func loadMobileDashboardAccessToken() async
        -> MobileDashboardAccessTokenLoadResult
    func saveMobileDashboardAccessToken(_ token: String) -> Bool
}

struct MobileDashboardKeychainTokenStore:
    MobileDashboardAccessTokenStoring
{
    func loadMobileDashboardAccessToken() async
        -> MobileDashboardAccessTokenLoadResult
    {
        await KeychainService.shared.mobileDashboardAccessToken()
    }

    func saveMobileDashboardAccessToken(_ token: String) -> Bool {
        KeychainService.shared.saveMobileDashboardAccessToken(token)
    }
}

actor MobileDashboardAccessTokenExecutor {
    private let store: any MobileDashboardAccessTokenStoring

    init(store: any MobileDashboardAccessTokenStoring) {
        self.store = store
    }

    func load() async -> MobileDashboardAccessTokenLoadResult {
        await store.loadMobileDashboardAccessToken()
    }

    func save(_ token: String) -> Bool {
        store.saveMobileDashboardAccessToken(token)
    }
}

struct MobileDashboardTokenMigrationStateV1:
    Codable,
    Equatable,
    Sendable
{
    enum Status: String, Codable, Sendable {
        case generatedFresh
        case explicitlySaved
    }

    static let currentVersion = 1
    var version: Int
    var status: Status

    init(status: Status) {
        version = Self.currentVersion
        self.status = status
    }
}

struct CredentialVaultV1: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var providers: [String: String]
    var cloudSyncToken: String?
    var mobileDashboardAccessToken: String?
    var mobileDashboardTokenMigration:
        MobileDashboardTokenMigrationStateV1?

    init(
        providers: [String: String] = [:],
        cloudSyncToken: String? = nil,
        mobileDashboardAccessToken: String? = nil,
        mobileDashboardTokenMigration:
            MobileDashboardTokenMigrationStateV1? = nil
    ) {
        version = Self.currentVersion
        self.providers = providers
        self.cloudSyncToken = cloudSyncToken
        self.mobileDashboardAccessToken = mobileDashboardAccessToken
        self.mobileDashboardTokenMigration =
            mobileDashboardTokenMigration
    }

    static func decodeCompatible(from data: Data) throws -> Self {
        if let vault = try? JSONDecoder().decode(Self.self, from: data) {
            guard vault.version == currentVersion else {
                throw CredentialVaultError.unsupportedVersion(
                    vault.version)
            }
            if let migration = vault.mobileDashboardTokenMigration,
               migration.version
                != MobileDashboardTokenMigrationStateV1.currentVersion {
                throw CredentialVaultError
                    .unsupportedMobileTokenMigrationVersion(
                        migration.version)
            }
            return vault
        }

        let legacy = try JSONDecoder().decode(
            [String: String].self,
            from: data)
        var providers = legacy
        let cloudSyncToken = providers.removeValue(
            forKey: "cloudSyncToken")
        // The historical dictionary never owned the dashboard token. Ignore
        // an injected key rather than silently reviving an old bearer token.
        providers.removeValue(forKey: "mobileDashboardAccessToken")
        return Self(
            providers: providers,
            cloudSyncToken: cloudSyncToken,
            mobileDashboardAccessToken: nil)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

enum CredentialVaultError: Error, Equatable {
    case unsupportedVersion(Int)
    case unsupportedMobileTokenMigrationVersion(Int)
}

enum CredentialVaultItemReadResult: Sendable, Equatable {
    case found(Data)
    case notFound
    case failure(OSStatus)
}

protocol CredentialVaultBackend: Sendable {
    func read(account: String, service: String)
        -> CredentialVaultItemReadResult
    func write(_ data: Data, account: String, service: String) -> OSStatus
    func delete(account: String, service: String) -> OSStatus
}

struct SystemCredentialVaultBackend: CredentialVaultBackend {
    func read(
        account: String,
        service: String
    ) -> CredentialVaultItemReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result)
        if status == errSecItemNotFound {
            return .notFound
        }
        guard status == errSecSuccess else {
            return .failure(status)
        }
        guard let data = result as? Data else {
            return .failure(errSecDecode)
        }
        return .found(data)
    }

    func write(
        _ data: Data,
        account: String,
        service: String
    ) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleWhenUnlocked,
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            update as CFDictionary)
        if updateStatus == errSecSuccess {
            return errSecSuccess
        }
        guard updateStatus == errSecItemNotFound else {
            return updateStatus
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] =
            kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            return SecItemUpdate(
                query as CFDictionary,
                update as CFDictionary)
        }
        return addStatus
    }

    func delete(account: String, service: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary)
    }
}

actor CredentialVaultStore {
    private enum LoadResult: Sendable {
        case found(CredentialVaultV1)
        case notFound
        case failure(OSStatus)
    }

    private enum CachedState {
        case found(CredentialVaultV1)
        case notFound
    }

    private enum LegacyStringResult {
        case found(String)
        case notFound
        case failure(OSStatus)
    }

    private struct VaultLoadInFlight {
        let id: UUID
        let task: Task<CredentialVaultItemReadResult, Never>
    }

    static let shared = CredentialVaultStore(
        backend: SystemCredentialVaultBackend(),
        service: KeychainService.service,
        vaultAccount: "providerCredentials",
        legacyServices: ["com.minimax.usagemonitor"])

    private let backend: any CredentialVaultBackend
    private let service: String
    private let vaultAccount: String
    private let legacyServices: [String]
    private let mobileTokenGenerator: @Sendable () -> String?
    private var cachedState: CachedState?
    private var vaultLoad: VaultLoadInFlight?

    init(
        backend: any CredentialVaultBackend,
        service: String = KeychainService.service,
        vaultAccount: String = "providerCredentials",
        legacyServices: [String] = ["com.minimax.usagemonitor"],
        mobileTokenGenerator: @escaping @Sendable () -> String? = {
            CredentialVaultStore.generateMobileAccessToken()
        }
    ) {
        self.backend = backend
        self.service = service
        self.vaultAccount = vaultAccount
        self.legacyServices = legacyServices
        self.mobileTokenGenerator = mobileTokenGenerator
    }

    func preload() async -> CredentialVaultV1? {
        guard case let .found(vault) = await loadVault() else {
            return nil
        }
        return vault
    }

    func credential(for provider: UsageProvider) async -> String? {
        let loadResult = await loadVault()
        if case let .found(vault) = loadResult,
           let value = vault.providers[provider.rawValue] {
            return value
        }
        let legacyResult = readLegacyString(
            account: provider.keychainAccount,
            services: [service] + legacyServices)
        guard case let .found(value) = legacyResult else {
            return nil
        }
        guard var vault = writableVault(from: loadResult) else {
            return value
        }
        vault.providers[provider.rawValue] = value
        if writeVault(vault) {
            cachedState = .found(vault)
        }
        return value
    }

    func saveCredential(
        _ credential: String,
        for provider: UsageProvider
    ) async -> Bool {
        await mutateVault { vault in
            vault.providers[provider.rawValue] = credential
        }
    }

    func deleteCredential(for provider: UsageProvider) async -> Bool {
        let saved = await mutateVault { vault in
            vault.providers.removeValue(forKey: provider.rawValue)
        }
        guard saved else { return false }
        return deleteLegacy(
            account: provider.keychainAccount,
            services: [service] + legacyServices)
    }

    func cloudSyncToken() async -> String? {
        let loadResult = await loadVault()
        if case let .found(vault) = loadResult,
           let token = vault.cloudSyncToken {
            return token
        }
        let legacyResult = readLegacyString(
            account: "cloudSyncToken",
            services: [service])
        guard case let .found(token) = legacyResult else {
            return nil
        }
        guard var vault = writableVault(from: loadResult) else {
            return token
        }
        vault.cloudSyncToken = token
        if writeVault(vault) {
            cachedState = .found(vault)
        }
        return token
    }

    func saveCloudSyncToken(_ token: String) async -> Bool {
        await mutateVault { vault in
            vault.cloudSyncToken = token
        }
    }

    func deleteCloudSyncToken() async -> Bool {
        let saved = await mutateVault { vault in
            vault.cloudSyncToken = nil
        }
        guard saved else { return false }
        return deleteLegacy(
            account: "cloudSyncToken",
            services: [service])
    }

    func mobileDashboardAccessToken() async
        -> MobileDashboardAccessTokenLoadResult
    {
        let loadResult = await loadVault()
        if case let .found(vault) = loadResult,
           let token = vault.mobileDashboardAccessToken,
           !token.isEmpty {
            return .found(token)
        }

        guard var vault = writableVault(from: loadResult) else {
            if case let .failure(status) = loadResult {
                return .failure(status)
            }
            return .failure(errSecNotAvailable)
        }
        guard let token = mobileTokenGenerator(),
              token.utf8.count == 43,
              token.utf8.allSatisfy({ byte in
                  (65...90).contains(byte)
                      || (97...122).contains(byte)
                      || (48...57).contains(byte)
                      || byte == 45
                      || byte == 95
              }) else {
            return .failure(errSecNotAvailable)
        }
        vault.mobileDashboardAccessToken = token
        vault.mobileDashboardTokenMigration =
            MobileDashboardTokenMigrationStateV1(
                status: .generatedFresh)
        let status = writeVaultStatus(vault)
        guard status == errSecSuccess else {
            // Never expose or cache a bearer token that was not persisted.
            return .failure(status)
        }
        cachedState = .found(vault)
        return .found(token)
    }

    func saveMobileDashboardAccessToken(_ token: String) async -> Bool {
        guard !token.isEmpty else { return false }
        return await mutateVault { vault in
            vault.mobileDashboardAccessToken = token
            vault.mobileDashboardTokenMigration =
                MobileDashboardTokenMigrationStateV1(
                    status: .explicitlySaved)
        }
    }

    func deleteMobileDashboardAccessToken() async -> Bool {
        await mutateVault { vault in
            vault.mobileDashboardAccessToken = nil
            vault.mobileDashboardTokenMigration = nil
        }
    }

    private func loadVault() async -> LoadResult {
        if let cachedState {
            switch cachedState {
            case let .found(vault): return .found(vault)
            case .notFound: return .notFound
            }
        }

        let inFlight: VaultLoadInFlight
        if let vaultLoad {
            inFlight = vaultLoad
        } else {
            let backend = backend
            let service = service
            let vaultAccount = vaultAccount
            let task = Task.detached(priority: .userInitiated) {
                backend.read(
                    account: vaultAccount,
                    service: service)
            }
            let next = VaultLoadInFlight(id: UUID(), task: task)
            vaultLoad = next
            inFlight = next
        }

        let readResult = await inFlight.task.value
        let ownsLoad = vaultLoad?.id == inFlight.id
        if ownsLoad {
            vaultLoad = nil
        } else if let cachedState {
            // Another waiter already committed this load and may also have
            // completed a synchronous mutation before this waiter resumed.
            // Return the actor's newest state, never the old task snapshot.
            switch cachedState {
            case let .found(vault): return .found(vault)
            case .notFound: return .notFound
            }
        }
        switch readResult {
        case let .found(data):
            do {
                let vault = try CredentialVaultV1
                    .decodeCompatible(from: data)
                if ownsLoad {
                    cachedState = .found(vault)
                }
                return .found(vault)
            } catch {
                KeychainService.reportCredentialDecodeFailure(error)
                return .failure(errSecDecode)
            }
        case .notFound:
            if ownsLoad {
                cachedState = .notFound
            }
            return .notFound
        case let .failure(status):
            return .failure(status)
        }
    }

    private func writableVault(
        from result: LoadResult
    ) -> CredentialVaultV1? {
        switch result {
        case let .found(vault): return vault
        case .notFound: return CredentialVaultV1()
        case .failure: return nil
        }
    }

    /// All read-modify-write work after `loadVault` is synchronous inside the
    /// actor. This intentionally prevents actor reentrancy from committing a
    /// stale base vault over another credential mutation.
    private func mutateVault(
        _ mutation: (inout CredentialVaultV1) -> Void
    ) async -> Bool {
        let loadResult = await loadVault()
        guard var vault = writableVault(from: loadResult) else {
            return false
        }
        mutation(&vault)
        guard writeVault(vault) else { return false }
        cachedState = .found(vault)
        return true
    }

    private func writeVault(_ vault: CredentialVaultV1) -> Bool {
        writeVaultStatus(vault) == errSecSuccess
    }

    private func writeVaultStatus(
        _ vault: CredentialVaultV1
    ) -> OSStatus {
        guard let data = try? vault.encoded() else {
            return errSecParam
        }
        return backend.write(
            data,
            account: vaultAccount,
            service: service)
    }

    nonisolated static func generateMobileAccessToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(
            kSecRandomDefault,
            bytes.count,
            &bytes) == errSecSuccess else {
            return nil
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func readLegacyString(
        account: String,
        services: [String]
    ) -> LegacyStringResult {
        for service in services {
            switch backend.read(account: account, service: service) {
            case let .found(data):
                guard let value = String(data: data, encoding: .utf8),
                      !value.isEmpty else {
                    return .failure(errSecDecode)
                }
                return .found(value)
            case .notFound:
                continue
            case let .failure(status):
                return .failure(status)
            }
        }
        return .notFound
    }

    private func deleteLegacy(
        account: String,
        services: [String]
    ) -> Bool {
        services.allSatisfy { service in
            let status = backend.delete(
                account: account,
                service: service)
            return status == errSecSuccess
                || status == errSecItemNotFound
        }
    }
}

final class KeychainService: @unchecked Sendable {
    static let shared = KeychainService()
    static let service = "com.techfanseric.aiquotabar"
    static let didFailToDecodeCredentials = Notification.Name(
        "KeychainService.didFailToDecodeCredentials")
    static let credentialsDecodeErrorUserInfoKey = "error"

    private let configuredProvidersDefaultsKey =
        "keychainConfiguredProviderKeys"
    private let vault: CredentialVaultStore
    private let defaults: UserDefaults

    init(
        vault: CredentialVaultStore = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.vault = vault
        self.defaults = defaults
    }

    func preloadCredentialVault() {
        if let loaded = blocking({ [vault] in
            await vault.preload()
        }) {
            cacheConfiguredProviderKeys(from: loaded.providers)
        }
    }

    func saveCredential(
        _ credential: String,
        for provider: UsageProvider
    ) -> Bool {
        let saved = blocking { [vault] in
            await vault.saveCredential(credential, for: provider)
        }
        if saved {
            cacheConfiguredProvider(provider, isConfigured: true)
        }
        return saved
    }

    func getCredential(for provider: UsageProvider) -> String? {
        let value = blocking { [vault] in
            await vault.credential(for: provider)
        }
        if value != nil {
            cacheConfiguredProvider(provider, isConfigured: true)
        }
        return value
    }

    func credential(for provider: UsageProvider) async -> String? {
        let value = await vault.credential(for: provider)
        if value != nil {
            cacheConfiguredProvider(provider, isConfigured: true)
        }
        return value
    }

    @discardableResult
    func deleteCredential(for provider: UsageProvider) -> Bool {
        let deleted = blocking { [vault] in
            await vault.deleteCredential(for: provider)
        }
        if deleted {
            cacheConfiguredProvider(provider, isConfigured: false)
        }
        return deleted
    }

    func hasCredential(for provider: UsageProvider) -> Bool {
        Set(defaults.stringArray(
            forKey: configuredProvidersDefaultsKey) ?? [])
            .contains(provider.rawValue)
    }

    func saveAPIKey(_ key: String) -> Bool {
        saveCredential(key, for: .miniMax)
    }

    func getAPIKey() -> String? {
        getCredential(for: .miniMax)
    }

    @discardableResult
    func deleteAPIKey() -> Bool {
        deleteCredential(for: .miniMax)
    }

    var hasAPIKey: Bool {
        hasCredential(for: .miniMax)
    }

    func saveCloudSyncToken(_ token: String) -> Bool {
        blocking { [vault] in
            await vault.saveCloudSyncToken(token)
        }
    }

    func getCloudSyncToken() -> String? {
        blocking { [vault] in
            await vault.cloudSyncToken()
        }
    }

    @discardableResult
    func deleteCloudSyncToken() -> Bool {
        blocking { [vault] in
            await vault.deleteCloudSyncToken()
        }
    }

    func mobileDashboardAccessToken() async
        -> MobileDashboardAccessTokenLoadResult
    {
        await vault.mobileDashboardAccessToken()
    }

    func saveMobileDashboardAccessTokenAsync(
        _ token: String
    ) async -> Bool {
        await vault.saveMobileDashboardAccessToken(token)
    }

    func saveMobileDashboardAccessToken(_ token: String) -> Bool {
        blocking { [vault] in
            await vault.saveMobileDashboardAccessToken(token)
        }
    }

    func loadMobileDashboardAccessToken()
        -> MobileDashboardAccessTokenLoadResult
    {
        blocking { [vault] in
            await vault.mobileDashboardAccessToken()
        }
    }

    @discardableResult
    func deleteMobileDashboardAccessToken() -> Bool {
        blocking { [vault] in
            await vault.deleteMobileDashboardAccessToken()
        }
    }

    static func reportCredentialDecodeFailure(_ error: Error) {
        NSLog(
            "KeychainService: failed to decode credential vault: %@. Original keychain entry will not be overwritten.",
            error.localizedDescription)
        NotificationCenter.default.post(
            name: didFailToDecodeCredentials,
            object: nil,
            userInfo: [credentialsDecodeErrorUserInfoKey: error])
    }

    private func cacheConfiguredProviderKeys(
        from providers: [String: String]
    ) {
        let keys = UsageProvider.allCases.compactMap { provider in
            providers[provider.rawValue] == nil
                ? nil
                : provider.rawValue
        }
        defaults.set(
            keys,
            forKey: configuredProvidersDefaultsKey)
    }

    private func cacheConfiguredProvider(
        _ provider: UsageProvider,
        isConfigured: Bool
    ) {
        var keys = Set(defaults.stringArray(
            forKey: configuredProvidersDefaultsKey) ?? [])
        if isConfigured {
            keys.insert(provider.rawValue)
        } else {
            keys.remove(provider.rawValue)
        }
        defaults.set(
            keys.sorted(),
            forKey: configuredProvidersDefaultsKey)
    }

    private func blocking<T: Sendable>(
        _ operation: @escaping @Sendable () async -> T
    ) -> T {
        let box = BlockingResultBox<T>()
        Task.detached {
            box.finish(await operation())
        }
        return box.wait()
    }
}

private final class BlockingResultBox<Value: Sendable>:
    @unchecked Sendable
{
    private let condition = NSCondition()
    private var values: [Value] = []

    func finish(_ value: Value) {
        condition.lock()
        values = [value]
        condition.signal()
        condition.unlock()
    }

    func wait() -> Value {
        condition.lock()
        while values.isEmpty {
            condition.wait()
        }
        let result = values[0]
        condition.unlock()
        return result
    }
}
