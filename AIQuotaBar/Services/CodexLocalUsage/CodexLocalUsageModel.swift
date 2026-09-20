import AppKit
import Foundation
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
    var verifyingDelivery = false
    var deliveryVerification: String?
    var deliveryVerificationMatches: Bool?
    var quotaQueueStats: CloudSyncQueue.Statistics?
    var sourceLogBytes: Int64 = 0
    var storageStats: UsageStore.StorageStats?
    var lastUploadConfirmedAt: Date?
    var nextUploadAttemptAt: Date?
    private var displayedRevision: Int?
    private var displayedWindow: Date?
    var delivery: [String: Int] = [:]
    var rejectionReasons: [String: Int] = [:]
    var teamRows: [TeamUsageRow] = []
    var teamDevices: [TeamUsageRow] = []
    var teamAccounts: [TeamUsageRow] = []
    var connection: LocalUsageConnection?
    var createdTeam: UsageTeamCreated?
    var connectingTeam = false
    var teamLoading = false
    var teamLoadError: String?
    var teamUpdatedAt: Date?
    var canManageTeam = false
    private var teamRequest = UUID()
    var days = 30
    var selectedAccount = "all" { didSet { historyCache.removeAll(); summaryCache.removeAll() } }
    var currentAccountID: String? { didSet { historyCache.removeAll(); summaryCache.removeAll() } }
    func refreshCurrentAccount() {
        let observation = UsageAccountObservation.read(root: root)
        if currentAccountID != observation.accountID { currentAccountID = observation.accountID }
        if let id = observation.accountID, let label = observation.label { accountLabels[id] = label }
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

    /// Time enters the cache key so an open menu advances across hours and months.
    func activityHistory(month: Bool, currentAccount: Bool = false, now: Date = Date()) -> [UsageHistoryBucket] {
        _ = events.count; _ = prices.count; _ = selectedAccount; _ = currentAccountID
        let key = "activity|\(month)|\(currentAccount)|\(Int(now.timeIntervalSince1970 / 60))|\(Calendar.current.timeZone.identifier)"
        if let cached = historyCache[key] { return cached }
        let scoped = trendEvents(currentAccount: currentAccount)
        let result = month ? UsageHistory.month(events: scoped, prices: prices, now: now)
            : UsageHistory.last24Hours(events: scoped, prices: prices, now: now)
        // Bound minute-keyed caches while leaving space for both account scopes.
        if historyCache.count > 16 { historyCache.removeAll() }
        historyCache[key] = result
        return result
    }
    func monthSummary(currentAccount: Bool = false, now: Date = Date()) -> UsageSummary {
        let from = Calendar.current.dateInterval(of: .month, for: now)!.start
        return UsageSummary(events: trendEvents(currentAccount: currentAccount), prices: prices, from: from, to: now)
    }

    init(defaults: UserDefaults = .standard, databaseURL: URL? = nil, client: UsageClient? = nil) {
        self.client = client
        self.defaults = defaults
        lastUploadConfirmedAt = defaults.object(forKey: "localUsage.lastUploadConfirmedAt") as? Date
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
        timer?.tolerance = 5
        Task {
            await refresh()
            if CommandLine.arguments.contains("--verify-usage-delivery") { await verifyCloudDelivery() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil; syncTask?.cancel() }
    func refresh() async {
        refreshCurrentAccount()
        guard !scanning, let store else { return }
        scanning = true
        defer { scanning = false }
        do {
            // The visible local charts need this month/30 days plus the rolling 24h.
            // Older durable records stay on disk, available for delivery and future retention migration.
            let window = Calendar.current.date(byAdding: .day, value: -35, to: Calendar.current.startOfDay(for: Date()))!
            let result = try await store.scan(root: root, binding: reportingEnabled ? connection?.binding : nil,
                since: connection?.since ?? .distantFuture, observation: UsageAccountObservation.read(root: root), eventsSince: window)
            accountLabels = try await store.accountTimeline().labels
            if displayedRevision != result.revision || displayedWindow != window {
                events = result.events; displayedRevision = result.revision; displayedWindow = window
            }
            quotaQueueStats = CloudSyncService.shared.queueStatistics()
            sourceLogBytes = result.sourceLogBytes
            files = result.files; issues = result.issues; deferred = result.deferred; incomplete = result.incomplete
            storageStats = try await store.storageStats()
            lastScan = Date(); error = nil
            if let connection {
                delivery = try await store.deliveryCounts(binding: connection.binding)
                rejectionReasons = try await store.rejectionReasons(binding: connection.binding)
            }
        } catch { self.error = error.localizedDescription }
        guard reportingEnabled, !syncing, Date() >= nextAttempt else { return }
        syncTask = Task { await sync() }
    }
    @discardableResult func connect(endpoint: String, token: String, includeHistory: Bool) async -> Bool {
        guard !syncing else { return false }
        do {
            let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let client = try UsageClient(endpoint: endpoint, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
            let result = try await client.identity()
            guard result.identity.device_id == deviceID else { throw UsageFailure.invalid("This credential belongs to another device. Register the device ID shown here.") }
            let same = connection?.endpoint == endpoint && connection?.identity.bindingID == result.identity.bindingID
            let since = includeHistory ? Date(timeIntervalSince1970: 0) : (same ? connection!.since : Date())
            let value = LocalUsageConnection(endpoint: endpoint, identity: result.identity, since: since)
            try await Self.saveToken(token.trimmingCharacters(in: .whitespacesAndNewlines), account: value.binding)
            defaults.set(try JSONEncoder().encode(value), forKey: "localUsage.connection")
            if !same { reportingEnabled = false; clearTeamSummary(); canManageTeam = false; syncStatus = "" }
            connection = value; self.client = client; try savePrices(result.prices)
            NotificationCenter.default.post(name: .teamConnectionChanged, object: nil)
            failures = 0; nextAttempt = .distantPast; error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    /// Self-service join: exchange an invite code and a display name for a
    /// device credential, then bind exactly like an admin-provisioned device.
    func joinTeam(inviteCode: String, memberName: String, passphrase: String, endpoint: String?, includeHistory: Bool) async -> Bool {
        guard !syncing, !connectingTeam else { return false }
        connectingTeam = true
        defer { connectingTeam = false }
        return await performJoin(inviteCode: inviteCode, memberName: memberName, passphrase: passphrase, endpoint: endpoint, includeHistory: includeHistory)
    }
    private func performJoin(inviteCode: String, memberName: String, passphrase: String, endpoint: String?, includeHistory: Bool) async -> Bool {
        let trimmed = endpoint?.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let origin = trimmed.isEmpty ? CloudSyncSettings.defaultEndpointURLString : trimmed
        do {
            let response = try await UsageClient.join(endpoint: origin, inviteCode: inviteCode, memberName: memberName, deviceID: deviceID, memberPassphrase: passphrase)
            guard await connect(endpoint: origin, token: response.token, includeHistory: includeHistory) else { return false }
            reportingEnabled = true
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func createTeam(name: String, memberName: String, passphrase: String, includeHistory: Bool) async -> Bool {
        guard !connectingTeam, !syncing else { return false }
        connectingTeam = true
        defer { connectingTeam = false }
        do {
            // Keep one-time credentials visible even if joining fails; retry must not create a second team.
            if createdTeam == nil { createdTeam = try await UsageClient.createTeam(endpoint: CloudSyncSettings.defaultEndpointURLString, name: name) }
            guard let team = createdTeam else { return false }
            try await Self.saveToken(team.loginPassword, account: managerBinding(endpoint: CloudSyncSettings.defaultEndpointURLString, teamID: team.teamID))
            return await performJoin(inviteCode: team.inviteCode, memberName: memberName, passphrase: passphrase, endpoint: nil, includeHistory: includeHistory)
        } catch { self.error = error.localizedDescription; return false }
    }
    func leaveTeam() async {
        guard !connectingTeam, !syncing else { return }
        connectingTeam = true
        defer { connectingTeam = false }
        do {
            let client = try await activeClient()
            try await client.leave()
            reportingEnabled = false; syncTask?.cancel()
            connection = nil; self.client = nil; createdTeam = nil
            defaults.removeObject(forKey: "localUsage.connection")
            clearTeamSummary(); canManageTeam = false; delivery = [:]; rejectionReasons = [:]; syncStatus = ""; error = nil
            NotificationCenter.default.post(name: .teamConnectionChanged, object: nil)
        } catch { self.error = error.localizedDescription }
    }
    func quotaContext() async throws -> TeamQuotaContext {
        guard let connection else { throw CloudSyncError.missingToken }
        let token = try await Self.loadToken(account: connection.binding)
        guard self.connection?.binding == connection.binding else { throw CancellationError() }
        return TeamQuotaContext(binding: connection.binding, endpoint: connection.endpoint, token: token)
    }
    func setMemberPassphrase(_ passphrase: String) async {
        do {
            let client = try await activeClient()
            try await client.setMemberPassphrase(passphrase)
            syncStatus = "member passphrase saved"; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func importPrices(_ data: Data) {
        do { try savePrices(JSONDecoder().decode([UsagePrice].self, from: data)); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func savePrices(_ value: [UsagePrice]) throws {
        try UsagePrice.validate(value)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        if try encoder.encode(prices) != data {
            defaults.set(data, forKey: "localUsage.prices"); prices = value
        }
    }
    private func activeClient() async throws -> UsageClient {
        guard let connection else { throw UsageFailure.invalid("Connect a registered device first") }
        if let client { return client }
        let value = try UsageClient(endpoint: connection.endpoint, token: await Self.loadToken(account: connection.binding))
        guard self.connection?.binding == connection.binding else { throw CancellationError() }
        client = value; return value
    }
    private func sync() async {
        guard reportingEnabled, !syncing, !connectingTeam, let connection, let store else { return }
        syncing = true
        defer { syncing = false }
        do {
            let connection = try await migrateHostedConnection(connection, store: store)
            let client = try await activeClient()
            let identity = try await client.identity()
            guard identity.identity.bindingID == connection.identity.bindingID else { throw UsageFailure.invalid("Server identity changed; reconnect this device") }
            guard self.connection?.binding == connection.binding else { return }
            try savePrices(identity.prices)
            // Drain a bounded amount per pass; the durable outbox resumes next pass.
            for _ in 0..<20 {
                try Task.checkCancellation()
                guard reportingEnabled, self.connection?.binding == connection.binding else { return }
                let batch = try await store.pending(binding: connection.binding)
                if batch.isEmpty { break }
                let receipt = try await client.send(batch)
                try await store.acknowledge(binding: connection.binding, ids: receipt.accepted, rejected: receipt.rejected.map(\.id), reasons: Dictionary(uniqueKeysWithValues: receipt.rejected.map { ($0.id, $0.reason) }))
                if !receipt.accepted.isEmpty {
                    lastUploadConfirmedAt = Date()
                    defaults.set(lastUploadConfirmedAt, forKey: "localUsage.lastUploadConfirmedAt")
                }
                if !receipt.rejected.isEmpty { syncStatus = receipt.rejected.map(\.reason).joined(separator: ", ") }
            }
            guard self.connection?.binding == connection.binding else { return }
            delivery = try await store.deliveryCounts(binding: connection.binding)
            rejectionReasons = try await store.rejectionReasons(binding: connection.binding)
            syncStatus = "\(delivery["sent", default: 0]) sent · \(delivery["pending", default: 0]) pending · \(delivery["rejected", default: 0]) rejected"
            storageStats = try await store.storageStats()
            failures = 0; nextAttempt = .distantPast; nextUploadAttemptAt = nil
        } catch is CancellationError { return }
        catch {
            guard self.connection?.binding == connection.binding else { return }
            failures += 1
            nextAttempt = Date().addingTimeInterval(min(3600, 60 * pow(2, Double(min(failures - 1, 6)))))
            syncStatus = error.localizedDescription
            if syncStatus.contains("401") { nextAttempt = .distantFuture; client = nil }
            nextUploadAttemptAt = nextAttempt
            // Successful earlier batches remain visible even if a later batch fails.
            delivery = (try? await store.deliveryCounts(binding: connection.binding)) ?? delivery
            rejectionReasons = (try? await store.rejectionReasons(binding: connection.binding)) ?? rejectionReasons
            storageStats = (try? await store.storageStats()) ?? storageStats
        }
    }
    /// Compare a fixed acknowledged time range with the server using this device's
    /// existing credential. No historic local-only records are uploaded by this check.
    func verifyCloudDelivery() async {
        guard !verifyingDelivery, let connection, let store else { return }
        verifyingDelivery = true
        defer { verifyingDelivery = false }
        do {
            let client = try await activeClient()
            let records = try await store.confirmedEvents(binding: connection.binding)
            guard let first = records.first.flatMap({ UsageTime.parse($0.occurredAt) }),
                  let last = records.last.flatMap({ UsageTime.parse($0.occurredAt) }) else {
                deliveryVerification = "No acknowledged records to verify."; deliveryVerificationMatches = nil; return
            }
            let expected = UsageSummary(events: records)
            let end = last.addingTimeInterval(0.001)
            var cursor = first, serverRecords = 0
            var serverTokens = UsageTokens()
            while cursor < end {
                try Task.checkCancellation()
                let next = min(end, cursor.addingTimeInterval(365 * 86400))
                let series = try await client.timeline(from: cursor, to: next, bucketSeconds: 86400,
                    member: connection.identity.member_id, device: connection.identity.device_id)
                for row in series.groups {
                    serverRecords += row.records
                    serverTokens = serverTokens + row.summary.tokens
                }
                cursor = next
            }
            guard self.connection?.binding == connection.binding else { return }
            let matches = expected.records == serverRecords && expected.tokens == serverTokens
            deliveryVerificationMatches = matches
            let language = AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .english
            deliveryVerification = language == .simplifiedChinese
                ? "云端核验：本地已确认 \(expected.records.formatted()) 条 / 云端 \(serverRecords.formatted()) 条；\(matches ? "记录数与各项 token 总量一致" : "存在差异，需检查共享事件或上报状态")。"
                : "Cloud check: \(expected.records.formatted()) local acknowledged / \(serverRecords.formatted()) remote; \(matches ? "record and token totals match" : "mismatch; check shared events or delivery state")."
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AIQuotaBar/Diagnostics")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let report: [String: Any] = ["checkedAt": UsageTime.string(Date()), "from": UsageTime.string(first),
                "to": UsageTime.string(end), "localRecords": expected.records, "remoteRecords": serverRecords,
                "localTokens": expected.tokens.total, "remoteTokens": serverTokens.total, "allTokenFieldsMatch": expected.tokens == serverTokens,
                "matches": matches]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("usage-delivery-audit.json"), options: .atomic)
        } catch {
            deliveryVerificationMatches = false
            deliveryVerification = error.localizedDescription
        }
    }

    private func migrateHostedConnection(_ old: LocalUsageConnection, store: UsageStore) async throws -> LocalUsageConnection {
        guard ["https://ai-quota-bar-sync.techfanseric.workers.dev", "https://quota.talktrace.app"].contains(old.endpoint) else { return old }
        let token = try await Self.loadToken(account: old.binding)
        let target = CloudSyncSettings.defaultEndpointURLString
        let client = try UsageClient(endpoint: target, token: token)
        let identity = try await client.identity()
        guard identity.identity.bindingID == old.identity.bindingID else { throw UsageFailure.invalid("Migration identity mismatch") }
        let updated = LocalUsageConnection(endpoint: target, identity: old.identity, since: old.since)
        try await Self.saveToken(token, account: updated.binding)
        try await store.migrateBinding(from: old.binding, to: updated.binding)
        defaults.set(try JSONEncoder().encode(updated), forKey: "localUsage.connection")
        self.connection = updated; self.client = client
        return updated
    }

    func clearTeamSummary() {
        teamRequest = UUID(); teamLoading = false; teamLoadError = nil; teamUpdatedAt = nil
        teamRows = []; teamDevices = []; teamAccounts = []
    }
    private func managerBinding(endpoint: String, teamID: String) -> String {
        "team-manager:" + usageDigest(endpoint + "|" + teamID)
    }
    func refreshManagementAccess() async {
        guard let connection else { canManageTeam = false; return }
        let saved = await KeychainService.shared.deviceCredential(binding: managerBinding(endpoint: connection.endpoint, teamID: connection.identity.team_id))
        guard self.connection?.binding == connection.binding else { return }
        canManageTeam = saved?.isEmpty == false
    }
    func teamBrowserURL(manage: Bool, password: String? = nil) async throws -> URL {
        guard let connection, !connectingTeam else { throw UsageFailure.invalid("Join a team first") }
        let key = managerBinding(endpoint: connection.endpoint, teamID: connection.identity.team_id)
        var credential: String?
        if manage {
            if let password { credential = password }
            else { credential = await KeychainService.shared.deviceCredential(binding: key) }
            guard let credential, !credential.isEmpty else { throw UsageFailure.invalid("Enter the team's management password once") }
        }
        let client = try await activeClient()
        let url: URL
        do { url = try await client.teamBrowserURL(managementPassword: credential) }
        catch {
            if manage, self.connection?.binding == connection.binding, error.localizedDescription.contains("401") { canManageTeam = false }
            throw error
        }
        guard self.connection?.binding == connection.binding else { throw CancellationError() }
        if let password, manage {
            try await Self.saveToken(password, account: key)
            guard self.connection?.binding == connection.binding else { throw CancellationError() }
            canManageTeam = true
        }
        return url
    }
    func loadTeam() async {
        guard !Task.isCancelled else { return }
        guard let connection else { clearTeamSummary(); return }
        let requestID = UUID(); teamRequest = requestID
        let requestedDays = days, requestedFrom = from, requestedBinding = connection.binding
        teamLoading = true; teamLoadError = nil
        defer { if teamRequest == requestID { teamLoading = false } }
        do {
            let client = try await activeClient()
            let identity = try await client.identity()
            guard teamRequest == requestID, requestedBinding == self.connection?.binding else { return }
            try savePrices(identity.prices)
            let to = Date()
            async let members = client.summary(from: requestedFrom, to: to, group: "member")
            async let devices = client.summary(from: requestedFrom, to: to, group: "device")
            async let accounts = client.summary(from: requestedFrom, to: to, group: "account")
            let result = try await (members, devices, accounts)
            guard teamRequest == requestID, requestedDays == days, requestedBinding == self.connection?.binding else { return }
            teamRows = result.0; teamDevices = result.1; teamAccounts = result.2; teamUpdatedAt = Date()
        } catch {
            guard !Task.isCancelled, teamRequest == requestID, requestedDays == days, requestedBinding == self.connection?.binding else { return }
            if (error as? URLError)?.code == .cancelled { return }
            teamLoadError = error.localizedDescription
        }
    }
    func teamActivity(member: String?, device: String?, account: String?, date: Date?, now: Date) async throws -> (daily: [UsageHistoryBucket], hourly: [UsageHistoryBucket]) {
        guard let binding = connection?.binding else { throw UsageFailure.invalid("Join a team first") }
        let client = try await activeClient()
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let month = calendar.dateInterval(of: .month, for: date ?? now)!
        let start = date.map { calendar.startOfDay(for: $0) } ?? now.addingTimeInterval(-86400)
        let end = date == nil ? now : start.addingTimeInterval(86400)
        async let daily = client.timeline(from: month.start, to: month.end, bucketSeconds: 86400, member: member, device: device, account: account)
        async let hourly = client.timeline(from: start, to: end, bucketSeconds: 300, member: member, device: device, account: account)
        let result = try await (daily, hourly)
        guard connection?.binding == binding else { throw CancellationError() }
        return (result.0.buckets, result.1.buckets)
    }
    private static func saveToken(_ token: String, account: String) async throws {
        guard await KeychainService.shared.saveDeviceCredential(token, binding: account) else {
            throw UsageFailure.invalid("Could not save device credential to Keychain")
        }
    }
    private static func loadToken(account: String) async throws -> String {
        guard let token = await KeychainService.shared.deviceCredential(binding: account) else {
            throw UsageFailure.invalid("Device credential unavailable; reconnect in Local usage settings")
        }
        return token
    }
}

extension Notification.Name {
    static let teamConnectionChanged = Notification.Name("AIQuotaBar.teamConnectionChanged")
}
