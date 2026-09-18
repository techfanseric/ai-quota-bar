import AppKit
import Foundation
import Security
import LocalAuthentication
import CodexLocalUsageCore

struct LocalUsageConnection: Codable {
    let endpoint: String
    let identity: UsageIdentity
    let since: Date
    var binding: String { usageDigest(endpoint + "|" + identity.bindingID) }
}

/// Independent of quota polling, OAuth and Codex app presence.
@MainActor @Observable
final class CodexLocalUsageModel {
    static let shared = CodexLocalUsageModel()
    var events: [LocalUsageEvent] = [] { didSet { historyCache.removeAll(); summaryCache.removeAll() } }
    var prices: [UsagePrice] = [] { didSet { historyCache.removeAll(); summaryCache.removeAll() } }
    var scanStatus = ""
    var syncStatus = ""
    var error: String?
    var scanning = false
    var syncing = false
    var lastScan: Date?
    var files = 0
    var issues = 0
    var deferred = 0
    var incomplete = 0
    var delivery: [String: Int] = [:]
    var rejectionReasons: [String: Int] = [:]
    var teamRows: [TeamUsageRow] = []
    var teamDevices: [TeamUsageRow] = []
    var teamAccounts: [TeamUsageRow] = []
    var connection: LocalUsageConnection?
    var days = 7
    var selectedAccount = "all" { didSet { historyCache.removeAll(); summaryCache.removeAll() } }
    var currentAccountID: String? { didSet { historyCache.removeAll(); summaryCache.removeAll() } }
    func refreshCurrentAccount() {
        currentAccountID = UsageAccountObservation.read(root: root).accountID
    }
    private func trendEvents(currentAccount: Bool) -> [LocalUsageEvent] {
        guard currentAccount else { return filteredEvents }
        guard let currentAccountID else { return [] }
        return events.filter { $0.accountID == currentAccountID }
    }
    var accountLabels: [String: String] = [:]
    var accountIDs: [String] { Set(events.compactMap(\.accountID)).sorted() }
    var filteredEvents: [LocalUsageEvent] {
        switch selectedAccount {
        case "all": return events
        case "unknown": return events.filter { $0.accountID == nil }
        default: return events.filter { $0.accountID == selectedAccount }
        }
    }
    var reportingEnabled: Bool {
        didSet {
            defaults.set(reportingEnabled, forKey: "localUsage.reporting")
            if !reportingEnabled { syncTask?.cancel() }
            else { nextAttempt = .distantPast; failures = 0; Task { await refresh() } }
        }
    }
    private var store: UsageStore?
    private var timer: Timer?
    private var syncTask: Task<Void, Never>?
    private var nextAttempt = Date.distantPast
    private var failures = 0
    private var client: UsageClient?
    private let defaults: UserDefaults
    var deviceID: String { CloudSyncSettings.current.deviceID }
    var root: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex", isDirectory: true)
    }
    var from: Date { Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: Date()))! }
    var summary: UsageSummary { UsageSummary(events: filteredEvents, prices: prices, from: from, to: Date().addingTimeInterval(1)) }
    var today: UsageSummary { UsageSummary(events: filteredEvents, prices: prices, from: Calendar.current.startOfDay(for: Date()), to: Date().addingTimeInterval(1)) }

    @ObservationIgnored private var historyCache: [String: [UsageHistoryBucket]] = [:]
    @ObservationIgnored private var summaryCache: [String: UsageSummary] = [:]
    func history(days: Int, currentAccount: Bool = false) -> [UsageHistoryBucket] {
        _ = events.count; _ = prices.count; _ = selectedAccount; _ = currentAccountID // Track observable invalidation for both views.
        let key = "\(days)|\(currentAccount)"
        if let cached = historyCache[key] { return cached }
        let value = UsageHistory.buckets(events: trendEvents(currentAccount: currentAccount), prices: prices, days: days)
        historyCache[key] = value
        return value
    }
    func rangeSummary(days: Int, currentAccount: Bool = false) -> UsageSummary {
        _ = events.count; _ = prices.count; _ = selectedAccount; _ = currentAccountID
        let key = "\(days)|\(currentAccount)"
        if let cached = summaryCache[key] { return cached }
        let from = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: Date()))!
        let value = UsageSummary(events: trendEvents(currentAccount: currentAccount), prices: prices, from: from, to: Date().addingTimeInterval(1))
        summaryCache[key] = value
        return value
    }

    init(defaults: UserDefaults = .standard, databaseURL: URL? = nil) {
        self.defaults = defaults
        reportingEnabled = defaults.bool(forKey: "localUsage.reporting")
        if let data = defaults.data(forKey: "localUsage.connection") { connection = try? JSONDecoder().decode(LocalUsageConnection.self, from: data) }
        if let data = defaults.data(forKey: "localUsage.prices"), let decoded = try? JSONDecoder().decode([UsagePrice].self, from: data), (try? UsagePrice.validate(decoded)) != nil { prices = decoded }
        do {
            let url = databaseURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AIQuotaBar/local-usage.sqlite")
            store = try UsageStore(url: url)
        } catch { self.error = error.localizedDescription }
    }
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in await self?.refresh() } }
        Task { await refresh() }
    }
    func stop() { timer?.invalidate(); timer = nil; syncTask?.cancel() }
    func refresh() async {
        refreshCurrentAccount()
        guard !scanning, let store else { return }
        scanning = true
        defer { scanning = false }
        do {
            let result = try await store.scan(root: root, binding: reportingEnabled ? connection?.binding : nil, since: connection?.since ?? .distantFuture, observation: UsageAccountObservation.read(root: root))
            accountLabels = try await store.accountTimeline().labels
            events = result.events; files = result.files; issues = result.issues; deferred = result.deferred; incomplete = result.incomplete
            lastScan = Date(); error = nil
            if let connection {
                delivery = try await store.deliveryCounts(binding: connection.binding)
                rejectionReasons = try await store.rejectionReasons(binding: connection.binding)
            }
        } catch { self.error = error.localizedDescription }
        guard reportingEnabled, !syncing, Date() >= nextAttempt else { return }
        syncTask = Task { await sync() }
    }
    func connect(endpoint: String, token: String, includeHistory: Bool) async {
        guard !syncing else { return }
        do {
            let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let client = try UsageClient(endpoint: endpoint, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
            let result = try await client.identity()
            guard result.identity.device_id == deviceID else { throw UsageFailure.invalid("This credential belongs to another device. Register the device ID shown here.") }
            let same = connection?.endpoint == endpoint && connection?.identity.bindingID == result.identity.bindingID
            let since = includeHistory ? Date(timeIntervalSince1970: 0) : (same ? connection!.since : Date())
            let value = LocalUsageConnection(endpoint: endpoint, identity: result.identity, since: since)
            try Self.saveToken(token.trimmingCharacters(in: .whitespacesAndNewlines), account: value.binding)
            defaults.set(try JSONEncoder().encode(value), forKey: "localUsage.connection")
            if !same { reportingEnabled = false; teamRows = []; teamDevices = []; syncStatus = "" }
            connection = value; self.client = client; try savePrices(result.prices)
            failures = 0; nextAttempt = .distantPast; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func importPrices(_ data: Data) {
        do { try savePrices(JSONDecoder().decode([UsagePrice].self, from: data)); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func savePrices(_ value: [UsagePrice]) throws {
        try UsagePrice.validate(value)
        defaults.set(try JSONEncoder().encode(value), forKey: "localUsage.prices"); prices = value
    }
    private func activeClient() throws -> UsageClient {
        guard let connection else { throw UsageFailure.invalid("Connect a registered device first") }
        if let client { return client }
        let value = try UsageClient(endpoint: connection.endpoint, token: Self.loadToken(account: connection.binding))
        client = value; return value
    }
    private func sync() async {
        guard reportingEnabled, !syncing, let connection, let store else { return }
        syncing = true
        defer { syncing = false }
        do {
            let connection = try await migrateHostedConnection(connection, store: store)
            let client = try activeClient()
            let identity = try await client.identity()
            guard identity.identity.bindingID == connection.identity.bindingID else { throw UsageFailure.invalid("Server identity changed; reconnect this device") }
            try savePrices(identity.prices)
            // Drain a bounded amount per pass; the durable outbox resumes next pass.
            for _ in 0..<20 {
                try Task.checkCancellation()
                guard reportingEnabled else { return }
                let batch = try await store.pending(binding: connection.binding)
                if batch.isEmpty { break }
                let receipt = try await client.send(batch)
                try await store.acknowledge(binding: connection.binding, ids: receipt.accepted, rejected: receipt.rejected.map(\.id), reasons: Dictionary(uniqueKeysWithValues: receipt.rejected.map { ($0.id, $0.reason) }))
                if !receipt.rejected.isEmpty { syncStatus = receipt.rejected.map(\.reason).joined(separator: ", ") }
            }
            delivery = try await store.deliveryCounts(binding: connection.binding)
            rejectionReasons = try await store.rejectionReasons(binding: connection.binding)
            syncStatus = "\(delivery["sent", default: 0]) sent · \(delivery["pending", default: 0]) pending · \(delivery["rejected", default: 0]) rejected"
            failures = 0; nextAttempt = .distantPast
        } catch is CancellationError { return }
        catch {
            failures += 1
            nextAttempt = Date().addingTimeInterval(min(3600, 60 * pow(2, Double(min(failures - 1, 6)))))
            syncStatus = error.localizedDescription
            if syncStatus.contains("401") { nextAttempt = .distantFuture; client = nil }
        }
    }
    private func migrateHostedConnection(_ old: LocalUsageConnection, store: UsageStore) async throws -> LocalUsageConnection {
        guard ["https://ai-quota-bar-sync.techfanseric.workers.dev", "https://quota.talktrace.app"].contains(old.endpoint) else { return old }
        let token = try Self.loadToken(account: old.binding)
        let target = CloudSyncSettings.defaultEndpointURLString
        let client = try UsageClient(endpoint: target, token: token)
        let identity = try await client.identity()
        guard identity.identity.bindingID == old.identity.bindingID else { throw UsageFailure.invalid("Migration identity mismatch") }
        let updated = LocalUsageConnection(endpoint: target, identity: old.identity, since: old.since)
        try Self.saveToken(token, account: updated.binding)
        try await store.migrateBinding(from: old.binding, to: updated.binding)
        defaults.set(try JSONEncoder().encode(updated), forKey: "localUsage.connection")
        self.connection = updated; self.client = client
        return updated
    }

    func loadTeam() async {
        let requestedDays = days, requestedFrom = from, requestedBinding = connection?.binding
        do {
            let client = try activeClient()
            let identity = try await client.identity()
            try savePrices(identity.prices)
            async let members = client.summary(from: requestedFrom, to: Date(), group: "member")
            async let devices = client.summary(from: requestedFrom, to: Date(), group: "device")
            async let accounts = client.summary(from: requestedFrom, to: Date(), group: "account")
            let result = try await (members, devices, accounts)
            guard requestedDays == days, requestedBinding == connection?.binding else { return }
            teamRows = result.0; teamDevices = result.1; teamAccounts = result.2; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private static func saveToken(_ token: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.techfanseric.aiquotabar.local-usage", kSecAttrAccount as String: account]
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var added = query; added[kSecValueData as String] = data; added[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(added as CFDictionary, nil) == errSecSuccess else { throw UsageFailure.invalid("Could not save device credential to Keychain") }
        } else if status != errSecSuccess { throw UsageFailure.invalid("Could not update device credential in Keychain") }
    }
    private static func loadToken(account: String) throws -> String {
        let context = LAContext(); context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.techfanseric.aiquotabar.local-usage", kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne, kSecUseAuthenticationContext as String: context]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else { throw UsageFailure.invalid("Device credential unavailable; reconnect in Local usage settings") }
        return token
    }
}
