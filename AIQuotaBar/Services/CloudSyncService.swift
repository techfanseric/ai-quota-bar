import Foundation

enum CloudSyncError: Error, LocalizedError {
    case disabled
    case invalidEndpoint
    case missingToken
    case invalidResponse
    case serverError(Int, String)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "Cloud sync is disabled."
        case .invalidEndpoint:
            return "Cloud sync URL is invalid."
        case .missingToken:
            return "Cloud sync token is missing."
        case .invalidResponse:
            return "Cloud sync returned an invalid response."
        case .serverError(let statusCode, let message):
            if CloudSyncService.isD1DailyLimitExceeded(statusCode: statusCode, message: message) {
                return "Cloud database daily quota exceeded; it resets at 00:00 UTC."
            }
            if CloudSyncService.isD1Error(statusCode: statusCode, message: message) {
                return "Cloud database error (\(statusCode)): \(message)"
            }
            return "Cloud sync failed (\(statusCode)): \(message)"
        case .network(let error):
            return Self.describeNetworkError(error)
        }
    }

    /// 把 URLError 翻译成可操作的诊断：超时/DNS/TLS/无连接分别给排查方向。
    private static func describeNetworkError(_ error: Error) -> String {
        guard let urlError = error as? URLError else {
            return error.localizedDescription
        }
        switch urlError.code {
        case .timedOut:
            return "请求超时：到同步服务器（workers.dev）的链路不通，请检查代理是否覆盖该域名"
        case .notConnectedToInternet:
            return "无网络连接"
        case .cannotFindHost, .dnsLookupFailed:
            return "DNS 解析失败：本机 DNS 可能被污染，试试走代理或更换 DNS"
        case .cannotConnectToHost:
            return "无法连接同步服务器"
        case .networkConnectionLost:
            return "连接中断，正在自动重试"
        case .secureConnectionFailed, .serverCertificateHasBadDate,
             .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            return "TLS 握手失败：加密链路被拦截，请检查代理节点"
        case .appTransportSecurityRequiresSecureConnection:
            return "connection blocked by App Transport Security"
        default:
            return "\(urlError.localizedDescription) (\(urlError.code.rawValue))"
        }
    }
}

struct CloudSyncSettings {
    static let enabledKey = "cloudSyncEnabled"
    static let endpointURLKey = "cloudSyncEndpointURL"
    static let deviceIDKey = "cloudSyncDeviceID"
    static let defaultEndpointURLString = "https://ai-quota-bar-sync.techfanseric.workers.dev"
    static let defaultServiceToken = "d7dac44143ffaa6e1fe1237add43723dcc10ce72330410483a49de8c8d62c038"

    var isEnabled: Bool
    var endpointURLString: String
    var deviceID: String

    var effectiveEndpointURLString: String {
        Self.defaultEndpointURLString
    }

    static func effectiveEndpointURLString(_ customEndpoint: String) -> String {
        defaultEndpointURLString
    }

    static func effectiveToken(_ customToken: String) -> String {
        defaultServiceToken
    }

    static var current: CloudSyncSettings {
        let defaults = UserDefaults.standard
        let existingDeviceID = defaults.string(forKey: deviceIDKey)
        let deviceID = existingDeviceID ?? UUID().uuidString

        if existingDeviceID == nil {
            defaults.set(deviceID, forKey: deviceIDKey)
        }

        return CloudSyncSettings(
            isEnabled: defaults.bool(forKey: enabledKey),
            endpointURLString: defaultEndpointURLString,
            deviceID: deviceID
        )
    }

    func save() {
        UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
        UserDefaults.standard.removeObject(forKey: Self.endpointURLKey)
        UserDefaults.standard.set(deviceID, forKey: Self.deviceIDKey)
    }
}

/// 同步状态机：`@Observable` 让 view（如 `GeneralPane`）能 watch 变化。
/// 所有写入都在 `@MainActor` 上下文（调用方均为 `UsageViewModel` 的 main-actor 方法），
/// 避免跨 actor 访问 `lastSyncStatus`。
@MainActor
@Observable
final class CloudSyncService {
    static let shared = CloudSyncService()

    private let session: URLSession
    private let encoder: JSONEncoder
    private let queue: CloudSyncQueue
    private let retryBackoffs: [UInt64]

    /// view 可读：`Last sync: 2m ago` 或 `Failed: 5m ago`
    private(set) var lastSyncStatus: CloudSyncStatus = .idle

    init(session: URLSession = .shared, retryBackoffs: [UInt64] = [1, 4, 16]) {
        self.session = session
        self.retryBackoffs = retryBackoffs
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        self.queue = CloudSyncQueue()
        // 启动时恢复上次状态：跨重启保留"上次同步 Xm ago"上下文
        self.lastSyncStatus = Self.loadPersistedStatus()
    }

    /// 同步当前 quota 快照 + 跨周期 utilization 历史到云端。
    /// - 历史项可空；为空时 payload 仍可成功（服务端忽略）。
    /// - 失败时不抛给上层 — 由调用方通过 `lastSyncStatus` 查询；
    ///   失败 payload 已落盘到 `CloudSyncQueue`，下次调用时自动重试。
    /// - 启动时 `flushPendingQueue()` 先把堆积的 payload 推上去。
    func syncUsageData(
        _ usageData: UsageData,
        sampledAt: Date,
        utilizationHistories: [UsageProvider: ModelUtilizationStoreData]? = nil
    ) async {
        let settings = CloudSyncSettings.current
        guard settings.isEnabled else { return }

        let token = CloudSyncSettings.defaultServiceToken

        let request: URLRequest
        do {
            request = try makeRequest(
                endpointURLString: settings.effectiveEndpointURLString,
                path: "/v1/quota-samples",
                token: token,
                method: "POST"
            )
        } catch {
            recordFailure(reason: .invalidEndpoint, error: error)
            return
        }

        var historiesPayload: [String: [String: CloudUtilizationHistoryPayload]]?
        if let utilizationHistories {
            var byProvider: [String: [String: CloudUtilizationHistoryPayload]] = [:]
            for (provider, store) in utilizationHistories {
                var byModel: [String: CloudUtilizationHistoryPayload] = [:]
                for (modelId, history) in store.historiesOrEmpty {
                    byModel[modelId] = CloudUtilizationHistoryPayload(history: history)
                }
                byProvider[provider.rawValue] = byModel
            }
            historiesPayload = byProvider
        }

        let payload = CloudUsageSnapshotPayload(
            deviceID: settings.deviceID,
            sampledAt: sampledAt,
            retentionDays: CloudDataRetentionLimit.current.rawValue,
            models: usageData.models.map { CloudModelQuotaPayload(model: $0) },
            utilizationHistories: historiesPayload
        )

        let body: Data
        do {
            body = try encoder.encode(payload)
        } catch {
            recordFailure(reason: .encodingFailed, error: error)
            return
        }

        do {
            try await sendWithRetry(request: request, body: body)
            recordSuccess(at: Date())
        } catch is CancellationError {
            // 用户禁用云同步 / 切换 endpoint 等场景:不记录失败、不 enqueue payload,
            // 避免 UI 显示 "失败 Ym ago" 和队列堆积虚假任务
            return
        } catch {
            // 重试用尽，落盘到队列等下次刷新再推
            queue.enqueue(payload: payload)
            recordFailure(reason: .network, error: error)
        }
    }

    /// 启动时主动 flush 一次堆积队列（fire-and-forget，失败不重入队列避免死循环）
    func flushPendingQueue() async {
        let settings = CloudSyncSettings.current
        guard settings.isEnabled else { return }
        let token = CloudSyncSettings.defaultServiceToken

        let request: URLRequest
        do {
            request = try makeRequest(
                endpointURLString: settings.effectiveEndpointURLString,
                path: "/v1/quota-samples",
                token: token,
                method: "POST"
            )
        } catch {
            return
        }

        await queue.flush { [encoder, session] payload in
            let body = try encoder.encode(payload)
            var req = request
            req.httpBody = body
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let message = String(data: data, encoding: .utf8) ?? ""
                throw CloudSyncError.serverError(status, message)
            }
        }
    }

    /// 同步状态：UI 可读 `lastSyncStatus` 显示 "Last sync: 2m ago" 或 "Failed: 5m ago"
    private static let persistedStatusKey = "cloudSync.lastStatusSnapshot.v1"

    private func recordSuccess(at date: Date) {
        lastSyncStatus = .success(at: date)
        Self.persistStatus(lastSyncStatus)
    }

    private func recordFailure(reason: CloudSyncFailureReason, error: Error? = nil) {
        lastSyncStatus = .failure(at: Date(), reason: reason, error: error)
        Self.persistStatus(lastSyncStatus)
#if DEBUG
        if let error {
            print("CloudSync failure: \(reason) — \(error.localizedDescription)")
        } else {
            print("CloudSync failure: \(reason)")
        }
#endif
    }

    /// 把 status 快照落 UserDefaults。
    /// Error 不入快照（不可 Codable），重启后显示 reason 文本即可。
    private static func persistStatus(_ status: CloudSyncStatus) {
        let snapshot: StatusSnapshot?
        switch status {
        case .idle:
            snapshot = nil
        case .success(let date):
            snapshot = StatusSnapshot(kind: "success", date: date, reason: nil)
        case .failure(let date, let reason, _):
            snapshot = StatusSnapshot(kind: "failure", date: date, reason: reason.rawValue)
        }
        if let snapshot {
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: persistedStatusKey)
            }
        } else {
            UserDefaults.standard.removeObject(forKey: persistedStatusKey)
        }
    }

    private static func loadPersistedStatus() -> CloudSyncStatus {
        guard let data = UserDefaults.standard.data(forKey: persistedStatusKey),
              let snapshot = try? JSONDecoder().decode(StatusSnapshot.self, from: data) else {
            return .idle
        }
        switch snapshot.kind {
        case "success":
            return .success(at: snapshot.date)
        case "failure":
            let reason = snapshot.reason.flatMap(CloudSyncFailureReason.init(rawValue:)) ?? .network
            return .failure(at: snapshot.date, reason: reason, error: nil)
        default:
            return .idle
        }
    }

    private struct StatusSnapshot: Codable {
        let kind: String
        let date: Date
        let reason: String?
    }

    /// 重试 3 次：1s, 4s, 16s 指数退避
    /// 任务被 cancel 时 sleep 会抛 `CancellationError`，立即退出不再重试，
    /// 避免用户切 endpoint / disable cloud sync 后还在后台跑 21s。
    func sendWithRetry(request: URLRequest, body: Data) async throws {
        var lastError: Error?

        for attempt in 0...retryBackoffs.count {
            try Task.checkCancellation()

            var req = request
            req.httpBody = body
            do {
                let (data, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse else {
                    throw CloudSyncError.invalidResponse
                }
                if (200...299).contains(http.statusCode) {
                    return
                }
                let message = String(data: data, encoding: .utf8) ?? ""
                throw CloudSyncError.serverError(http.statusCode, message)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Permanent HTTP failures must escape this catch, not re-enter
                // the retry loop. Daily D1 quota cannot recover in seconds.
                if Self.isNonRetryable(error) {
                    throw error
                }
                lastError = error
            }

            if attempt < retryBackoffs.count {
                // 用 try 而非 try?：让 cancel 立即抛 CancellationError，循环立即退出，
                // 避免用户切 endpoint / disable cloud sync 后还在后台跑 21s 退避。
                try await Task.sleep(nanoseconds: retryBackoffs[attempt] * 1_000_000_000)
            }
        }

        throw lastError ?? CloudSyncError.invalidResponse
    }

    private static func isNonRetryable(_ error: Error) -> Bool {
        guard case let CloudSyncError.serverError(status, message) = error else {
            return false
        }
        if (400...499).contains(status) { return true }
        return isD1DailyLimitExceeded(statusCode: status, message: message)
    }

    /// 服务端 D1 当日配额耗尽：worker 分类后返回 503 `d1_daily_limit_exceeded`，
    /// 旧部署则是 500 内嵌原始 D1 报错文本。日配额秒级内不可能恢复，不重试。
    nonisolated static func isD1DailyLimitExceeded(statusCode: Int, message: String) -> Bool {
        guard (500...599).contains(statusCode) else { return false }
        let normalized = message.lowercased()
        guard normalized.contains("d1") else { return false }
        return normalized.contains("daily_limit")
            || normalized.contains("daily_read_limit")
            || normalized.contains("daily_write_limit")
            || ((normalized.contains("daily") || normalized.contains("per day"))
                && normalized.contains("exceeded")
                && (normalized.contains("row read") || normalized.contains("rows read")
                    || normalized.contains("row write") || normalized.contains("rows written")))
    }

    /// 任意 D1 层错误（worker 分类为 503 `d1_*`，或 500 内嵌 D1_ERROR 文本）。
    nonisolated static func isD1Error(statusCode: Int, message: String) -> Bool {
        guard (500...599).contains(statusCode) else { return false }
        return message.lowercased().contains("d1")
    }

    func deleteRemoteData(endpointURLString: String, token: String) async throws -> CloudDeleteDataResponse {
        let deviceID = Self.queryEscaped(CloudSyncSettings.current.deviceID)
        let request = try makeRequest(
            endpointURLString: endpointURLString,
            path: "/v1/data?device_id=\(deviceID)",
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            method: "DELETE"
        )
        let responseData = try await data(for: request)
        let decoder = JSONDecoder()
        return try decoder.decode(CloudDeleteDataResponse.self, from: responseData)
    }

    func deleteRemoteAccountData(
        provider: UsageProvider,
        accountName: String,
        endpointURLString: String,
        token: String
    ) async throws -> CloudDeleteDataResponse {
        let providerValue = Self.queryEscaped(provider.rawValue)
        let accountValue = Self.queryEscaped(accountName)
        let request = try makeRequest(
            endpointURLString: endpointURLString,
            path: "/v1/data?provider=\(providerValue)&account_name=\(accountValue)",
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            method: "DELETE"
        )
        let responseData = try await data(for: request)
        let decoder = JSONDecoder()
        return try decoder.decode(CloudDeleteDataResponse.self, from: responseData)
    }

    func fetchRemoteAccountSummaries(
        endpointURLString: String,
        token: String,
        limit: Int = 500
    ) async throws -> [CloudRemoteAccountSummary] {
        do {
            let request = try makeRequest(
                endpointURLString: endpointURLString,
                path: "/v1/account-summaries?limit=\(limit)",
                token: token.trimmingCharacters(in: .whitespacesAndNewlines),
                method: "GET"
            )
            let responseData = try await data(for: request)
            let decoder = JSONDecoder()
            let response = try decoder.decode(CloudAccountSummariesResponse.self, from: responseData)
            let summaries = response.accounts.compactMap { account -> CloudRemoteAccountSummary? in
                guard let provider = UsageProvider.cloudProvider(rawValue: account.provider) else { return nil }
                return CloudRemoteAccountSummary(
                    provider: provider,
                    accountName: account.accountName,
                    latestSampledAt: CloudRemoteQuotaSample.date(from: account.latestSampledAt) ?? .distantPast,
                    sampleCount: account.sampleCount,
                    modelCount: account.modelCount
                )
            }
            return summaries.sorted { lhs, rhs in
                if lhs.provider.rawValue != rhs.provider.rawValue {
                    return lhs.provider.rawValue < rhs.provider.rawValue
                }
                if lhs.latestSampledAt != rhs.latestSampledAt {
                    return lhs.latestSampledAt > rhs.latestSampledAt
                }
                return lhs.accountName.localizedStandardCompare(rhs.accountName) == .orderedAscending
            }
        } catch CloudSyncError.serverError(404, _) {
            // Older sync services do not expose account summaries. Fall back to latest samples.
        }

        let request = try makeRequest(
            endpointURLString: endpointURLString,
            path: "/v1/quota-samples?limit=\(limit)",
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            method: "GET"
        )
        let responseData = try await data(for: request)
        let decoder = JSONDecoder()
        let response = try decoder.decode(CloudQuotaSamplesResponse.self, from: responseData)

        let grouped = Dictionary(grouping: response.samples) { sample in
            [
                sample.provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                (sample.accountName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            ].joined(separator: ":")
        }

        return grouped.values.compactMap { samples in
            guard let first = samples.first,
                  let provider = UsageProvider.cloudProvider(rawValue: first.provider) else {
                return nil
            }
            let accountName = (first.accountName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let latestSampledAt = samples.map(\.sampledDate).max() ?? .distantPast
            let modelCount = Set(samples.map { $0.modelID ?? $0.modelName }).count
            return CloudRemoteAccountSummary(
                provider: provider,
                accountName: accountName,
                latestSampledAt: latestSampledAt,
                sampleCount: samples.count,
                modelCount: modelCount
            )
        }
        .sorted { lhs, rhs in
            if lhs.provider.rawValue != rhs.provider.rawValue {
                return lhs.provider.rawValue < rhs.provider.rawValue
            }
            if lhs.latestSampledAt != rhs.latestSampledAt {
                return lhs.latestSampledAt > rhs.latestSampledAt
            }
            return lhs.accountName.localizedStandardCompare(rhs.accountName) == .orderedAscending
        }
    }

    func fetchRemoteUsageData(limit: Int = 500) async throws -> [UsageProvider: UsageData] {
        let request = try makeRequest(
            endpointURLString: CloudSyncSettings.defaultEndpointURLString,
            path: "/v1/quota-samples?limit=\(limit)",
            token: CloudSyncSettings.defaultServiceToken,
            method: "GET"
        )
        let responseData = try await data(for: request)
        let decoder = JSONDecoder()
        let response = try decoder.decode(CloudQuotaSamplesResponse.self, from: responseData)
        return remoteUsageData(from: response.samples)
    }

    func fetchRemoteModelQuotaSamples(limit: Int = 500) async throws -> [String: [ModelQuotaSample]] {
        let request = try makeRequest(
            endpointURLString: CloudSyncSettings.defaultEndpointURLString,
            path: "/v1/quota-samples?history=1&limit=\(limit)",
            token: CloudSyncSettings.defaultServiceToken,
            method: "GET"
        )
        let responseData = try await data(for: request)
        let decoder = JSONDecoder()
        let response = try decoder.decode(CloudQuotaSamplesResponse.self, from: responseData)
        return remoteModelQuotaSamples(from: response.samples)
    }

    /// D1 当日配额状态（参考 TunnelWatchPage `/api/usage` widget）。
    /// 不抛错：worker 未部署该端点 / 未配 token / GraphQL 失败都归一为状态枚举，
    /// 设置面板按状态渲染，不打扰主流程。
    func fetchD1UsageState() async -> CloudD1UsageState {
        let request: URLRequest
        do {
            request = try makeRequest(
                endpointURLString: CloudSyncSettings.defaultEndpointURLString,
                path: "/v1/d1-usage",
                token: CloudSyncSettings.defaultServiceToken,
                method: "GET"
            )
        } catch {
            return .unavailable(error.localizedDescription)
        }

        do {
            let responseData = try await data(for: request)
            let usage = try JSONDecoder().decode(CloudD1Usage.self, from: responseData)
            return .available(usage)
        } catch CloudSyncError.serverError(_, let message) {
            if message.contains("missing_token") || message.contains("missing_config") {
                return .notConfigured
            }
            return .unavailable(message)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    func makeRemoteDataReport(endpointURLString: String, token: String, limit: Int = 300) async throws -> URL {
        let devicesRequest = try makeRequest(
            endpointURLString: endpointURLString,
            path: "/v1/devices",
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            method: "GET"
        )
        let samplesRequest = try makeRequest(
            endpointURLString: endpointURLString,
            path: "/v1/quota-samples?history=1&limit=\(limit)",
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            method: "GET"
        )

        async let devicesData = data(for: devicesRequest)
        async let samplesData = data(for: samplesRequest)

        let decoder = JSONDecoder()
        let devicesResponse = try decoder.decode(CloudDevicesResponse.self, from: try await devicesData)
        let samplesResponse = try decoder.decode(CloudQuotaSamplesResponse.self, from: try await samplesData)
        let html = remoteDataReportHTML(
            endpointURLString: endpointURLString,
            devices: devicesResponse.devices,
            samples: samplesResponse.samples
        )

        let reportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-quota-bar-remote-data.html")
        try html.write(to: reportURL, atomically: true, encoding: .utf8)
        return reportURL
    }

    func makeDataReport(
        snapshot: DataReportSnapshot,
        endpointURLString: String,
        token: String,
        includeCloud: Bool,
        limit: Int = 500
    ) async throws -> URL {
        var devices: [CloudRemoteDevice] = []
        var samples: [CloudRemoteQuotaSample] = []
        var accountSummaries: [CloudRemoteAccountDataSummary] = []
        var cloudError: String?
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldFetchCloud = includeCloud
            && !endpointURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !trimmedToken.isEmpty

        if shouldFetchCloud {
            do {
                let devicesRequest = try makeRequest(
                    endpointURLString: endpointURLString,
                    path: "/v1/devices",
                    token: trimmedToken,
                    method: "GET"
                )
                let samplesRequest = try makeRequest(
                    endpointURLString: endpointURLString,
                    path: "/v1/quota-samples?history=1&limit=\(limit)",
                    token: trimmedToken,
                    method: "GET"
                )

                async let devicesData = data(for: devicesRequest)
                async let samplesData = data(for: samplesRequest)

                let decoder = JSONDecoder()
                let devicesResponse = try decoder.decode(CloudDevicesResponse.self, from: try await devicesData)
                let samplesResponse = try decoder.decode(CloudQuotaSamplesResponse.self, from: try await samplesData)
                devices = devicesResponse.devices
                samples = samplesResponse.samples

                do {
                    let accountsRequest = try makeRequest(
                        endpointURLString: endpointURLString,
                        path: "/v1/account-summaries?limit=500",
                        token: trimmedToken,
                        method: "GET"
                    )
                    let accountsResponse = try decoder.decode(
                        CloudAccountSummariesResponse.self,
                        from: try await data(for: accountsRequest)
                    )
                    accountSummaries = accountsResponse.accounts
                } catch {
                    cloudError = "Account summaries unavailable: \(error.localizedDescription)"
                }
            } catch {
                cloudError = error.localizedDescription
            }
        }

        let html = dataReportHTML(
            snapshot: snapshot,
            endpointURLString: endpointURLString,
            cloudEnabled: includeCloud,
            cloudAttempted: shouldFetchCloud,
            cloudError: cloudError,
            devices: devices,
            accountSummaries: accountSummaries,
            remoteSamples: samples
        )

        let reportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-quota-bar-data.html")
        try html.write(to: reportURL, atomically: true, encoding: .utf8)
        return reportURL
    }

    func clearPendingQueue() {
        queue.clearAll()
    }

    private static func queryEscaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    private func remoteUsageData(from samples: [CloudRemoteQuotaSample]) -> [UsageProvider: UsageData] {
        let latestByModel = Dictionary(grouping: samples) { sample in
            sample.modelID ?? "\(sample.provider):\(sample.accountName ?? ""):\(sample.modelName)"
        }
        .compactMapValues { rows in
            rows.sorted { lhs, rhs in lhs.sampledDate > rhs.sampledDate }.first
        }

        let models = latestByModel.values.compactMap { sample -> ModelUsageData? in
            guard let provider = UsageProvider.cloudProvider(rawValue: sample.provider) else { return nil }
            let endTime = sample.resetEndDate
            let remaining = max(0, sample.currentIntervalRemaining)
            let total = max(0, sample.currentIntervalTotal)
            let percent = sample.chartPercent
            return ModelUsageData(
                provider: provider,
                accountName: sample.accountName,
                modelName: sample.modelName,
                currentIntervalTotal: total,
                currentIntervalUsed: remaining,
                weeklyTotal: sample.weeklyTotal,
                weeklyUsed: sample.weeklyRemaining,
                remainsTime: endTime.map { Int($0.timeIntervalSince(Date()) * 1000) } ?? 0,
                startTime: sample.resetStartDate,
                endTime: endTime,
                weeklyStartTime: sample.weeklyStartDate,
                weeklyEndTime: sample.weeklyEndDate,
                valueSuffix: sample.valueSuffix,
                detailText: sample.cloudDetailText,
                currentIntervalRemainingPercent: percent,
                weeklyRemainingPercent: nil,
                progressBarPercentOverride: nil,
                progressBarRightText: nil,
                sampledAt: sample.sampledDate)
        }

        let grouped = Dictionary(grouping: models, by: \.provider)
        return grouped.mapValues { providerModels in
            let latestTimestamp = providerModels
                .compactMap { model in
                    latestByModel[model.id]?.sampledDate
                }
                .max() ?? Date()
            return UsageData(
                provider: providerModels.first?.provider ?? .codex,
                remains: providerModels.filter(\.isCurrentIntervalAvailable).count,
                total: providerModels.count,
                timestamp: latestTimestamp,
                models: providerModels,
                subscribeTitle: nil,
                subscribeEndTime: nil)
        }
    }

    private func remoteModelQuotaSamples(from samples: [CloudRemoteQuotaSample]) -> [String: [ModelQuotaSample]] {
        var result: [String: [ModelQuotaSample]] = [:]

        for sample in samples {
            guard let modelID = sample.modelID,
                  let timestamp = CloudRemoteQuotaSample.date(from: sample.sampledAt) else {
                continue
            }
            if let start = sample.resetStartDate, timestamp < start {
                continue
            }
            if let end = sample.resetEndDate, timestamp > end {
                continue
            }

            let point = ModelQuotaSample(
                timestamp: timestamp,
                remaining: max(0, sample.currentIntervalRemaining),
                percent: sample.chartPercent
            )
            result[modelID, default: []].append(point)
        }

        return result.mapValues { samples in
            var byTimestamp: [TimeInterval: ModelQuotaSample] = [:]
            for sample in samples {
                byTimestamp[sample.id] = sample
            }
            return byTimestamp.values.sorted { $0.timestamp < $1.timestamp }
        }
    }

    private func makeRequest(endpointURLString: String, path: String, token: String, method: String) throws -> URLRequest {
        guard !token.isEmpty else { throw CloudSyncError.missingToken }

        let trimmedEndpoint = endpointURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmedEndpoint),
              components.scheme?.hasPrefix("http") == true,
              components.host?.isEmpty == false else {
            throw CloudSyncError.invalidEndpoint
        }

        let pathParts = path.split(separator: "?", maxSplits: 1).map(String.init)
        let requestPath = pathParts.first ?? ""
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let nextPath = requestPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, nextPath].filter { !$0.isEmpty }.joined(separator: "/")
        if pathParts.count > 1 {
            components.percentEncodedQuery = pathParts[1]
        }

        guard let url = components.url else { throw CloudSyncError.invalidEndpoint }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// 读取路径统一入口。瞬态网络错误（超时/DNS/TLS/断连）按 `retryBackoffs`
    /// 指数退避自动重试，与写入路径 `sendWithRetry` 对齐；
    /// `serverError`（4xx/5xx）与 `invalidResponse` 不可自愈，立即抛出。
    /// 任务被 cancel 时 checkCancellation/sleep 会抛 `CancellationError`，立即退出重试。
    private func data(for request: URLRequest) async throws -> Data {
        for attempt in 0...retryBackoffs.count {
            try Task.checkCancellation()
            do {
                return try await performRequest(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard case CloudSyncError.network = error,
                      attempt < retryBackoffs.count else {
                    throw error
                }
                try await Task.sleep(nanoseconds: retryBackoffs[attempt] * 1_000_000_000)
            }
        }
        // 循环必然在最后一次 attempt 内 return 或 throw，此处仅满足编译器
        throw CloudSyncError.invalidResponse
    }

    private func performRequest(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CloudSyncError.network(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudSyncError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw CloudSyncError.serverError(httpResponse.statusCode, message)
        }

        return data
    }

    private func remoteDataReportHTML(
        endpointURLString: String,
        devices: [CloudRemoteDevice],
        samples: [CloudRemoteQuotaSample]
    ) -> String {
        let generatedAt = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium)
        let deviceRows = devices.map { device in
            """
            <tr>
              <td>\(escapeHTML(device.id))</td>
              <td>\(escapeHTML(device.lastSeenAt))</td>
              <td>\(escapeHTML(device.createdAt))</td>
            </tr>
            """
        }.joined(separator: "\n")
        let sampleRows = samples.map { sample in
            """
            <tr>
              <td>\(escapeHTML(sample.sampledAt))</td>
              <td>\(escapeHTML(sample.provider))</td>
              <td>\(escapeHTML(sample.accountName ?? ""))</td>
              <td>\(escapeHTML(sample.modelName))</td>
              <td>\(sample.currentIntervalRemaining)</td>
              <td>\(sample.currentIntervalTotal)</td>
              <td>\(escapeHTML(sample.remainingPercentageText))</td>
              <td>\(escapeHTML(sample.resetEndTime ?? ""))</td>
            </tr>
            """
        }.joined(separator: "\n")

        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>AI Quota Bar Remote Data</title>
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 24px; color: #1f2328; }
            h1 { font-size: 24px; margin: 0 0 8px; }
            h2 { font-size: 16px; margin: 28px 0 10px; }
            .meta { color: #6e7781; font-size: 13px; margin-bottom: 18px; }
            table { border-collapse: collapse; width: 100%; font-size: 13px; }
            th, td { border-bottom: 1px solid #d8dee4; padding: 8px 10px; text-align: left; vertical-align: top; }
            th { background: #f6f8fa; font-weight: 600; position: sticky; top: 0; }
            code { background: #f6f8fa; border-radius: 4px; padding: 2px 5px; }
          </style>
        </head>
        <body>
          <h1>AI Quota Bar Remote Data</h1>
          <div class="meta">Worker: <code>\(escapeHTML(endpointURLString))</code> · Generated: \(escapeHTML(generatedAt)) · Samples: \(samples.count)</div>

          <h2>Devices</h2>
          <table>
            <thead><tr><th>Device ID</th><th>Last seen</th><th>Created</th></tr></thead>
            <tbody>\(deviceRows.isEmpty ? "<tr><td colspan=\"3\">No devices yet.</td></tr>" : deviceRows)</tbody>
          </table>

          <h2>Recent Quota Samples</h2>
          <table>
            <thead>
              <tr>
                <th>Sampled at</th><th>Provider</th><th>Account</th><th>Model</th>
                <th>Remaining</th><th>Total</th><th>%</th><th>Reset end</th>
              </tr>
            </thead>
            <tbody>\(sampleRows.isEmpty ? "<tr><td colspan=\"8\">No samples yet. Refresh quota in the app once cloud backup is enabled.</td></tr>" : sampleRows)</tbody>
          </table>
        </body>
        </html>
        """
    }

    private func dataReportHTML(
        snapshot: DataReportSnapshot,
        endpointURLString: String,
        cloudEnabled: Bool,
        cloudAttempted: Bool,
        cloudError: String?,
        devices: [CloudRemoteDevice],
        accountSummaries: [CloudRemoteAccountDataSummary],
        remoteSamples: [CloudRemoteQuotaSample]
    ) -> String {
        let localModels = snapshot.providerUsageData.values
            .flatMap(\.models)
            .sorted { lhs, rhs in
                if lhs.provider.rawValue != rhs.provider.rawValue { return lhs.provider.rawValue < rhs.provider.rawValue }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
        let remoteByModel = Dictionary(grouping: remoteSamples) { $0.modelID ?? "\($0.provider):\($0.accountName ?? ""):\($0.modelName)" }
        let sampleCount = snapshot.modelQuotaSamples.values.reduce(0) { $0 + $1.count }
        let historyCount = snapshot.utilizationHistories.values.reduce(0) { $0 + $1.historiesOrEmpty.count }
        let historyEntryCount = snapshot.utilizationHistories.values.reduce(0) { total, store in
            total + store.historiesOrEmpty.values.reduce(0) { $0 + $1.entries.count }
        }
        let generatedAt = localDateTime(snapshot.generatedAt)

        let accountRows = accountSummaries.map { account in
            """
            <tr class="filter-row" data-source="cloud" data-provider="\(escapeHTML(account.displayProviderRawValue))" data-account="\(escapeHTML(account.accountName))" data-search="\(escapeHTML(account.searchText))">
              <td><span class="pill cloud">cloud</span></td>
              <td>\(escapeHTML(account.displayProviderName))</td>
              <td>\(escapeHTML(account.displayAccountName))</td>
              <td>\(account.sampleCount)</td>
              <td>\(account.modelCount)</td>
              <td>\(escapeHTML(account.earliestSampledAt))</td>
              <td>\(escapeHTML(account.latestSampledAt))</td>
            </tr>
            """
        }.joined(separator: "\n")

        let providerOptions = Set(
            localModels.map { $0.provider.rawValue }
            + remoteSamples.map(\.provider)
            + accountSummaries.map(\.displayProviderRawValue)
        )
        .filter { !$0.isEmpty }
        .sorted()
        .map { "<option value=\"\(escapeHTML($0))\">\(escapeHTML($0))</option>" }
        .joined(separator: "\n")

        let accountOptions = Set(
            localModels.compactMap(\.accountName)
            + remoteSamples.compactMap(\.accountName)
            + accountSummaries.map(\.accountName)
        )
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        .map { "<option value=\"\(escapeHTML($0))\">\(escapeHTML($0))</option>" }
        .joined(separator: "\n")

        let modelRows = localModels.map { model in
            let remote = remoteByModel[model.id]?.sorted { $0.sampledAt > $1.sampledAt }.first
            let source = model.parsedDetail.source
            let cloudClass: String
            let cloudLabel: String
            switch source {
            case "Cloud":
                cloudClass = "cloud"
                cloudLabel = remote == nil ? "cloud cached" : "cloud"
            case "Mix":
                cloudClass = "mix"
                cloudLabel = "mix"
            default:
                cloudClass = remote == nil ? "local" : "synced"
                cloudLabel = remote == nil ? "local only" : "synced"
            }
            return """
            <tr class="filter-row" data-source="\(escapeHTML(cloudLabel))" data-provider="\(escapeHTML(model.provider.rawValue))" data-account="\(escapeHTML(model.accountName ?? ""))" data-search="\(escapeHTML([cloudLabel, model.provider.rawValue, model.accountName ?? "", model.modelName, model.id].joined(separator: " ")))">
              <td><span class="pill \(cloudClass)">\(cloudLabel)</span></td>
              <td>\(escapeHTML(model.provider.displayName))</td>
              <td>\(escapeHTML(model.accountName ?? ""))</td>
              <td><code>\(escapeHTML(model.modelName))</code></td>
              <td class="mono">\(escapeHTML(model.id))</td>
              <td>\(escapeHTML(model.currentIntervalRemainingText))</td>
              <td>\(model.currentIntervalTotal)</td>
              <td>\(escapeHTML(dateText(model.startTime)))</td>
              <td>\(escapeHTML(dateText(model.endTime)))</td>
              <td>\(escapeHTML(remote?.sampledAt ?? ""))</td>
            </tr>
            """
        }.joined(separator: "\n")

        let sampleRows = snapshot.modelQuotaSamples
            .flatMap { modelID, samples in samples.map { (modelID: modelID, sample: $0) } }
            .sorted { $0.sample.timestamp > $1.sample.timestamp }
            .map { row in
                """
                <tr class="filter-row" data-source="local" data-provider="" data-account="" data-search="\(escapeHTML([row.modelID, localDateTime(row.sample.timestamp)].joined(separator: " ")))">
                  <td><span class="pill local">local window</span></td>
                  <td class="mono">\(escapeHTML(row.modelID))</td>
                  <td>\(escapeHTML(localDateTime(row.sample.timestamp)))</td>
                  <td>\(row.sample.remaining)</td>
                  <td>\(row.sample.percent.map { "\($0)%" } ?? "")</td>
                </tr>
                """
            }.joined(separator: "\n")

        let historyRows = snapshot.utilizationHistories
            .flatMap { provider, store in
                store.historiesOrEmpty.values.map { (provider: provider, history: $0) }
            }
            .sorted { $0.history.modelId < $1.history.modelId }
            .map { row in
                let cycles = Set(row.history.entries.compactMap(\.resetsAt)).count
                let lastCapture = row.history.entries.map(\.capturedAt).max()
                let lastReset = row.history.entries.compactMap(\.resetsAt).max()
                let remote = remoteByModel[row.history.modelId]?.sorted { $0.sampledAt > $1.sampledAt }.first
                let cloudLabel = remote == nil ? "local history" : "model synced"
                return """
                <tr class="filter-row" data-source="\(escapeHTML(cloudLabel))" data-provider="\(escapeHTML(row.provider.rawValue))" data-account="\(escapeHTML(accountNameFromModelID(row.history.modelId)))" data-search="\(escapeHTML([cloudLabel, row.provider.rawValue, row.history.modelId].joined(separator: " ")))">
                  <td><span class="pill \(remote == nil ? "local" : "synced")">\(cloudLabel)</span></td>
                  <td>\(escapeHTML(row.provider.displayName))</td>
                  <td class="mono">\(escapeHTML(row.history.modelId))</td>
                  <td>\(row.history.entries.count)</td>
                  <td>\(cycles)</td>
                  <td>\(escapeHTML(dateText(lastCapture)))</td>
                  <td>\(escapeHTML(dateText(lastReset)))</td>
                </tr>
                """
            }.joined(separator: "\n")

        let deviceRows = devices.map { device in
            """
            <tr>
              <td class="mono">\(escapeHTML(device.id))</td>
              <td>\(escapeHTML(device.name ?? ""))</td>
              <td>\(escapeHTML(device.lastSeenAt))</td>
              <td>\(escapeHTML(device.createdAt))</td>
            </tr>
            """
        }.joined(separator: "\n")

        let remoteRows = remoteSamples.map { sample in
            """
            <tr class="filter-row" data-source="cloud" data-provider="\(escapeHTML(sample.provider))" data-account="\(escapeHTML(sample.accountName ?? ""))" data-search="\(escapeHTML(sample.searchText))">
              <td><span class="pill cloud">cloud</span></td>
              <td>\(escapeHTML(sample.sampledAt))</td>
              <td>\(escapeHTML(sample.provider))</td>
              <td>\(escapeHTML(sample.accountName ?? ""))</td>
              <td>\(escapeHTML(sample.modelName))</td>
              <td class="mono">\(escapeHTML(sample.modelID ?? ""))</td>
              <td>\(sample.currentIntervalRemaining)</td>
              <td>\(sample.currentIntervalTotal)</td>
              <td>\(escapeHTML(sample.remainingPercentageText))</td>
              <td>\(escapeHTML(sample.resetEndTime ?? ""))</td>
            </tr>
            """
        }.joined(separator: "\n")

        let rawJSON = escapeHTML(rawJSONString(snapshot) ?? "{}")
        let cloudState: String
        if let cloudError {
            cloudState = "Cloud check failed: \(escapeHTML(cloudError))"
        } else if cloudAttempted {
            cloudState = "Cloud checked: \(remoteSamples.count) remote samples, \(devices.count) devices"
        } else if cloudEnabled {
            cloudState = "Cloud enabled, but endpoint/token is incomplete"
        } else {
            cloudState = "Cloud disabled; local data only"
        }

        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>AI Quota Bar Data</title>
          <style>
            :root { color-scheme: light dark; --border: #d8dee4; --muted: #6e7781; --bg: #f6f8fa; --text: #1f2328; }
            @media (prefers-color-scheme: dark) { :root { --border: #30363d; --muted: #8b949e; --bg: #161b22; --text: #e6edf3; } }
            body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 24px; color: var(--text); }
            h1 { font-size: 24px; margin: 0 0 6px; }
            h2 { font-size: 16px; margin: 26px 0 10px; }
            .meta { color: var(--muted); font-size: 13px; margin-bottom: 16px; }
            .summary { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 10px; margin: 16px 0 20px; }
            .stat { border: 1px solid var(--border); border-radius: 8px; padding: 10px 12px; background: var(--bg); }
            .stat strong { display: block; font-size: 22px; }
            .stat span { color: var(--muted); font-size: 12px; }
            .filters { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; border: 1px solid var(--border); border-radius: 8px; padding: 10px; background: var(--bg); margin: 12px 0 20px; }
            .filters input, .filters select { font: inherit; font-size: 12px; padding: 6px 8px; border: 1px solid var(--border); border-radius: 6px; background: Canvas; color: var(--text); }
            .filters input { min-width: 260px; }
            .filters button { font: inherit; font-size: 12px; padding: 6px 10px; border: 1px solid var(--border); border-radius: 6px; background: Canvas; color: var(--text); }
            .filter-count { color: var(--muted); font-size: 12px; margin-left: auto; }
            table { border-collapse: collapse; width: 100%; font-size: 12px; }
            th, td { border-bottom: 1px solid var(--border); padding: 7px 9px; text-align: left; vertical-align: top; }
            th { background: var(--bg); font-weight: 600; position: sticky; top: 0; }
            code, .mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11px; }
            .pill { border-radius: 999px; padding: 2px 7px; font-size: 11px; white-space: nowrap; }
            .synced { background: #dafbe1; color: #116329; }
            .local { background: #fff8c5; color: #7d4e00; }
            .cloud { background: #ddf4ff; color: #0969da; }
            .mix { background: #f0e7ff; color: #6639ba; }
            details { margin-top: 24px; }
            pre { border: 1px solid var(--border); border-radius: 8px; padding: 12px; overflow: auto; background: var(--bg); }
          </style>
        </head>
        <body>
          <h1>AI Quota Bar Data</h1>
          <div class="meta">Generated: \(escapeHTML(generatedAt)) · Worker: <code>\(escapeHTML(endpointURLString.isEmpty ? "not configured" : endpointURLString))</code> · \(cloudState)</div>

          <div class="summary">
            <div class="stat"><strong>\(localModels.count)</strong><span>current models</span></div>
            <div class="stat"><strong>\(sampleCount)</strong><span>local window samples</span></div>
            <div class="stat"><strong>\(historyCount)</strong><span>history series</span></div>
            <div class="stat"><strong>\(historyEntryCount)</strong><span>history entries</span></div>
            <div class="stat"><strong>\(remoteSamples.count)</strong><span>remote samples</span></div>
            <div class="stat"><strong>\(accountSummaries.count)</strong><span>cloud accounts</span></div>
          </div>

          <div class="filters">
            <input id="search" type="search" placeholder="Filter account, provider, model, source...">
            <select id="sourceFilter">
              <option value="">All sources</option>
              <option value="cloud">Cloud</option>
              <option value="mix">Mix</option>
              <option value="local">Local</option>
              <option value="synced">Synced</option>
            </select>
            <select id="providerFilter">
              <option value="">All providers</option>
              \(providerOptions)
            </select>
            <select id="accountFilter">
              <option value="">All accounts</option>
              \(accountOptions)
            </select>
            <button type="button" id="resetFilters">Reset</button>
            <span class="filter-count" id="filterCount"></span>
          </div>

          <h2>Cloud Account Summary</h2>
          <table>
            <thead><tr><th>Source</th><th>Provider</th><th>Account</th><th>Samples</th><th>Models</th><th>Earliest sample</th><th>Latest sample</th></tr></thead>
            <tbody>\(accountRows.isEmpty ? "<tr><td colspan=\"7\">No cloud account summary available.</td></tr>" : accountRows)</tbody>
          </table>

          <h2>Current Models</h2>
          <table>
            <thead><tr><th>Cloud</th><th>Provider</th><th>Account</th><th>Model</th><th>Model ID</th><th>Remaining</th><th>Total</th><th>Start</th><th>Reset</th><th>Last remote sample</th></tr></thead>
            <tbody>\(modelRows.isEmpty ? "<tr><td colspan=\"10\">No current model data yet. Refresh once to populate this table.</td></tr>" : modelRows)</tbody>
          </table>

          <h2>Utilization Histories</h2>
          <table>
            <thead><tr><th>Cloud</th><th>Provider</th><th>Model ID</th><th>Entries</th><th>Cycles</th><th>Last capture</th><th>Last reset</th></tr></thead>
            <tbody>\(historyRows.isEmpty ? "<tr><td colspan=\"7\">No utilization history recorded yet.</td></tr>" : historyRows)</tbody>
          </table>

          <h2>Local Short-window Samples</h2>
          <table>
            <thead><tr><th>Source</th><th>Model ID</th><th>Timestamp</th><th>Remaining</th><th>Percent</th></tr></thead>
            <tbody>\(sampleRows.isEmpty ? "<tr><td colspan=\"5\">No local short-window samples recorded.</td></tr>" : sampleRows)</tbody>
          </table>

          <h2>Cloud Devices</h2>
          <table>
            <thead><tr><th>Device ID</th><th>Name</th><th>Last seen</th><th>Created</th></tr></thead>
            <tbody>\(deviceRows.isEmpty ? "<tr><td colspan=\"4\">No cloud device data available.</td></tr>" : deviceRows)</tbody>
          </table>

          <h2>Cloud Quota Samples</h2>
          <table>
            <thead><tr><th>Source</th><th>Sampled at</th><th>Provider</th><th>Account</th><th>Model</th><th>Model ID</th><th>Remaining</th><th>Total</th><th>%</th><th>Reset</th></tr></thead>
            <tbody>\(remoteRows.isEmpty ? "<tr><td colspan=\"10\">No cloud samples available.</td></tr>" : remoteRows)</tbody>
          </table>

          <details>
            <summary>Raw local snapshot JSON</summary>
            <pre>\(rawJSON)</pre>
          </details>
          <script>
            const search = document.getElementById('search');
            const sourceFilter = document.getElementById('sourceFilter');
            const providerFilter = document.getElementById('providerFilter');
            const accountFilter = document.getElementById('accountFilter');
            const resetFilters = document.getElementById('resetFilters');
            const filterCount = document.getElementById('filterCount');
            const rows = Array.from(document.querySelectorAll('.filter-row'));

            function normalized(value) {
              return (value || '').toLowerCase();
            }

            function applyFilters() {
              const query = normalized(search.value).trim();
              const source = normalized(sourceFilter.value);
              const provider = normalized(providerFilter.value);
              const account = normalized(accountFilter.value);
              let visible = 0;

              for (const row of rows) {
                const rowSource = normalized(row.dataset.source);
                const rowProvider = normalized(row.dataset.provider);
                const rowAccount = normalized(row.dataset.account);
                const rowSearch = normalized(row.dataset.search);
                const matches =
                  (!query || rowSearch.includes(query)) &&
                  (!source || rowSource.includes(source)) &&
                  (!provider || rowProvider === provider) &&
                  (!account || rowAccount === account);
                row.hidden = !matches;
                if (matches) visible += 1;
              }
              filterCount.textContent = `${visible}/${rows.length} rows`;
            }

            for (const control of [search, sourceFilter, providerFilter, accountFilter]) {
              control.addEventListener('input', applyFilters);
              control.addEventListener('change', applyFilters);
            }
            resetFilters.addEventListener('click', () => {
              search.value = '';
              sourceFilter.value = '';
              providerFilter.value = '';
              accountFilter.value = '';
              applyFilters();
            });
            applyFilters();
          </script>
        </body>
        </html>
        """
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else { return "" }
        return localDateTime(date)
    }

    private func accountNameFromModelID(_ id: String) -> String {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return "" }
        return parts[1]
    }

    private func localDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func rawJSONString(_ snapshot: DataReportSnapshot) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private struct CloudDevicesResponse: Decodable {
    let ok: Bool
    let devices: [CloudRemoteDevice]
}

private struct CloudQuotaSamplesResponse: Decodable {
    let ok: Bool
    let samples: [CloudRemoteQuotaSample]
}

private struct CloudAccountSummariesResponse: Decodable {
    let ok: Bool
    let accounts: [CloudRemoteAccountDataSummary]
}

private struct CloudRemoteAccountDataSummary: Decodable {
    let provider: String
    let accountName: String
    let sampleCount: Int
    let modelCount: Int
    let earliestSampledAt: String
    let latestSampledAt: String

    enum CodingKeys: String, CodingKey {
        case provider
        case accountName = "account_name"
        case sampleCount = "sample_count"
        case modelCount = "model_count"
        case earliestSampledAt = "earliest_sampled_at"
        case latestSampledAt = "latest_sampled_at"
    }

    var displayAccountName: String {
        accountName.isEmpty ? "No account" : accountName
    }

    var displayProviderRawValue: String {
        UsageProvider.cloudProvider(rawValue: provider)?.rawValue ?? provider
    }

    var displayProviderName: String {
        UsageProvider.cloudProvider(rawValue: provider)?.displayName ?? provider
    }

    var searchText: String {
        [
            "cloud",
            provider,
            displayProviderRawValue,
            displayProviderName,
            accountName,
            "\(sampleCount)",
            "\(modelCount)",
            earliestSampledAt,
            latestSampledAt
        ].joined(separator: " ")
    }
}

struct CloudDeleteDataResponse: Decodable {
    let ok: Bool
    let deletedQuotaSamples: Int
    let deletedDevices: Int
    let deletedSettings: Int

    enum CodingKeys: String, CodingKey {
        case ok
        case deletedQuotaSamples = "deleted_quota_samples"
        case deletedDevices = "deleted_devices"
        case deletedSettings = "deleted_settings"
    }
}

/// `/v1/d1-usage` 的配额快照（worker 端字段即此结构）。
struct CloudD1Usage: Decodable, Equatable {
    let rowsRead: Int
    let rowsWritten: Int
    let databaseRowsRead: Int
    let databaseRowsWritten: Int
    let remaining: Int
    let limit: Int
    let pct: Double
    let observedAt: String
    let resetsAt: String

    /// TunnelWatchPage 同款阈值：绿 <50% / 黄 50-80% / 红 ≥80%
    var severity: CloudD1UsageSeverity {
        if pct >= 80 { return .critical }
        if pct >= 50 { return .warning }
        return .normal
    }
}

enum CloudD1UsageSeverity: Equatable {
    case normal
    case warning
    case critical
}

/// D1 配额查询的三态：不打扰主流程，由设置面板按状态渲染。
enum CloudD1UsageState: Equatable {
    case available(CloudD1Usage)
    /// worker 未配 CF_API_TOKEN / CF_ACCOUNT_ID（503 missing_token / missing_config）
    case notConfigured
    /// 网络失败、端点未部署、GraphQL 失败等，附可读原因
    case unavailable(String)
}

struct CloudRemoteAccountSummary: Identifiable, Hashable {
    let provider: UsageProvider
    let accountName: String
    let latestSampledAt: Date
    let sampleCount: Int
    let modelCount: Int

    var id: String {
        "\(provider.rawValue):\(accountName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    var displayAccountName: String {
        accountName.isEmpty ? "No account" : accountName
    }
}

private struct CloudRemoteDevice: Decodable {
    let id: String
    let name: String?
    let createdAt: String
    let lastSeenAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
    }
}

private struct CloudRemoteQuotaSample: Decodable {
    let deviceID: String?
    let provider: String
    let accountName: String?
    let modelID: String?
    let modelName: String
    let currentIntervalTotal: Int
    let currentIntervalRemaining: Int
    let currentIntervalRemainingPercent: Int?
    let weeklyTotal: Int
    let weeklyRemaining: Int
    let weeklyRemainingPercent: Int?
    let resetStartTime: String?
    let resetEndTime: String?
    let weeklyStartTime: String?
    let weeklyEndTime: String?
    let valueSuffix: String?
    let detailText: String?
    let sampledAt: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        self.provider = try container.decode(String.self, forKey: .provider)
        self.accountName = try container.decodeIfPresent(String.self, forKey: .accountName)
        self.modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        self.modelName = try container.decode(String.self, forKey: .modelName)
        self.currentIntervalTotal = try container.decodeIfPresent(Int.self, forKey: .currentIntervalTotal) ?? 0
        self.currentIntervalRemaining = try container.decodeIfPresent(Int.self, forKey: .currentIntervalRemaining) ?? 0
        self.currentIntervalRemainingPercent = try container.decodeIfPresent(Int.self, forKey: .currentIntervalRemainingPercent)
        self.weeklyTotal = try container.decodeIfPresent(Int.self, forKey: .weeklyTotal) ?? 0
        self.weeklyRemaining = try container.decodeIfPresent(Int.self, forKey: .weeklyRemaining) ?? 0
        self.weeklyRemainingPercent = try container.decodeIfPresent(Int.self, forKey: .weeklyRemainingPercent)
        self.resetStartTime = try container.decodeIfPresent(String.self, forKey: .resetStartTime)
        self.resetEndTime = try container.decodeIfPresent(String.self, forKey: .resetEndTime)
        self.weeklyStartTime = try container.decodeIfPresent(String.self, forKey: .weeklyStartTime)
        self.weeklyEndTime = try container.decodeIfPresent(String.self, forKey: .weeklyEndTime)
        self.valueSuffix = try container.decodeIfPresent(String.self, forKey: .valueSuffix)
        self.detailText = try container.decodeIfPresent(String.self, forKey: .detailText)
        self.sampledAt = try container.decode(String.self, forKey: .sampledAt)
    }

    var remainingPercentageText: String {
        guard currentIntervalTotal > 0 else { return "" }
        let percentage = Double(currentIntervalRemaining) / Double(currentIntervalTotal) * 100
        return String(format: "%.1f%%", percentage)
    }

    var chartPercent: Int? {
        if let currentIntervalRemainingPercent {
            return currentIntervalRemainingPercent
        }
        if valueSuffix == "%" || currentIntervalTotal == 100 {
            return currentIntervalRemaining
        }
        return nil
    }

    var sampledDate: Date {
        Self.date(from: sampledAt) ?? .distantPast
    }

    var resetStartDate: Date? {
        Self.date(from: resetStartTime)
    }

    var resetEndDate: Date? {
        Self.date(from: resetEndTime)
    }

    var weeklyStartDate: Date? {
        Self.date(from: weeklyStartTime)
    }

    var weeklyEndDate: Date? {
        Self.date(from: weeklyEndTime)
    }

    var cloudDetailText: String? {
        let parts = (detailText ?? "")
            .components(separatedBy: " · ")
            .filter { !$0.isEmpty && !Self.isLocalSourceLabel($0) }
        guard !parts.isEmpty else { return "Cloud" }

        var nextParts: [String] = []
        var insertedCloud = false
        for part in parts {
            if part.hasPrefix("resets ") {
                if !insertedCloud {
                    nextParts.append("Cloud")
                    insertedCloud = true
                }
                nextParts.append(part)
            } else {
                nextParts.append(part)
            }
        }
        if !insertedCloud {
            nextParts.append("Cloud")
        }
        return nextParts.joined(separator: " · ")
    }

    var searchText: String {
        [
            "cloud",
            provider,
            accountName ?? "",
            modelName,
            modelID ?? "",
            sampledAt,
            resetEndTime ?? ""
        ].joined(separator: " ")
    }

    private static func isLocalSourceLabel(_ value: String) -> Bool {
        switch value.lowercased() {
        case "oauth", "codex cli", "openai web", "cli", "web", "cloud":
            return true
        default:
            return false
        }
    }

    static func date(from value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = iso8601WithFractionalSeconds.date(from: value) {
            return date
        }
        return iso8601.date(from: value)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case provider
        case accountName = "account_name"
        case modelID = "model_id"
        case modelName = "model_name"
        case currentIntervalTotal = "current_interval_total"
        case currentIntervalRemaining = "current_interval_remaining"
        case currentIntervalRemainingPercent = "current_interval_remaining_percent"
        case weeklyTotal = "weekly_total"
        case weeklyRemaining = "weekly_remaining"
        case weeklyRemainingPercent = "weekly_remaining_percent"
        case resetStartTime = "reset_start_time"
        case resetEndTime = "reset_end_time"
        case weeklyStartTime = "weekly_start_time"
        case weeklyEndTime = "weekly_end_time"
        case valueSuffix = "value_suffix"
        case detailText = "detail_text"
        case sampledAt = "sampled_at"
    }
}

struct CloudUsageSnapshotPayload: Codable {
    let deviceID: String
    let sampledAt: Date
    let retentionDays: Int?
    let models: [CloudModelQuotaPayload]
    /// 跨周期 utilization 历史：key = provider.rawValue，
    /// value = `modelId -> CloudUtilizationHistoryPayload`。
    /// 旧服务端忽略未知字段，向后兼容；新服务端用来重建用户历史。
    let utilizationHistories: [String: [String: CloudUtilizationHistoryPayload]]?
}

struct CloudModelQuotaPayload: Codable {
    let provider: String
    let accountName: String?
    let modelID: String
    let modelName: String
    let currentIntervalTotal: Int
    let currentIntervalRemaining: Int
    let currentIntervalRemainingPercent: Int?
    let weeklyTotal: Int
    let weeklyRemaining: Int
    let weeklyRemainingPercent: Int?
    let resetStartTime: Date?
    let resetEndTime: Date?
    let weeklyStartTime: Date?
    let weeklyEndTime: Date?
    let valueSuffix: String?
    let detailText: String?

    init(model: ModelUsageData) {
        self.provider = model.provider.rawValue
        self.accountName = model.accountName
        self.modelID = model.id
        self.modelName = model.modelName
        if let percent = model.currentIntervalRemainingPercent {
            self.currentIntervalTotal = 100
            self.currentIntervalRemaining = percent
        } else {
            self.currentIntervalTotal = model.currentIntervalTotal
            self.currentIntervalRemaining = model.currentIntervalRemaining
        }
        self.currentIntervalRemainingPercent = model.currentIntervalRemainingPercent
        self.weeklyTotal = model.weeklyTotal
        self.weeklyRemaining = model.weeklyRemaining
        self.weeklyRemainingPercent = model.weeklyRemainingPercent
        self.resetStartTime = model.startTime
        self.resetEndTime = model.endTime
        self.weeklyStartTime = model.weeklyStartTime
        self.weeklyEndTime = model.weeklyEndTime
        self.valueSuffix = model.currentIntervalRemainingPercent == nil ? model.valueSuffix : "%"
        self.detailText = model.detailText
    }
}
