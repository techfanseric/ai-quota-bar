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
            return "Cloud sync failed (\(statusCode)): \(message)"
        case .network(let error):
            return "Cloud sync network error: \(error.localizedDescription)"
        }
    }
}

struct CloudSyncSettings {
    static let enabledKey = "cloudSyncEnabled"
    static let endpointURLKey = "cloudSyncEndpointURL"
    static let deviceIDKey = "cloudSyncDeviceID"

    var isEnabled: Bool
    var endpointURLString: String
    var deviceID: String

    static var current: CloudSyncSettings {
        let defaults = UserDefaults.standard
        let existingDeviceID = defaults.string(forKey: deviceIDKey)
        let deviceID = existingDeviceID ?? UUID().uuidString

        if existingDeviceID == nil {
            defaults.set(deviceID, forKey: deviceIDKey)
        }

        return CloudSyncSettings(
            isEnabled: defaults.bool(forKey: enabledKey),
            endpointURLString: defaults.string(forKey: endpointURLKey) ?? "",
            deviceID: deviceID
        )
    }

    func save() {
        UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
        UserDefaults.standard.set(endpointURLString.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.endpointURLKey)
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

    /// view 可读：`Last sync: 2m ago` 或 `Failed: 5m ago`
    private(set) var lastSyncStatus: CloudSyncStatus = .idle

    private init(session: URLSession = .shared) {
        self.session = session
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

        let token = KeychainService.shared.getCloudSyncToken()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            recordFailure(reason: .missingToken)
            return
        }

        let request: URLRequest
        do {
            request = try makeRequest(
                endpointURLString: settings.endpointURLString,
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
        let token = KeychainService.shared.getCloudSyncToken()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { return }

        let request: URLRequest
        do {
            request = try makeRequest(
                endpointURLString: settings.endpointURLString,
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
    private func sendWithRetry(request: URLRequest, body: Data) async throws {
        let backoffs: [UInt64] = [1, 4, 16]
        var lastError: Error?

        for attempt in 0...backoffs.count {
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
                lastError = CloudSyncError.serverError(http.statusCode, message)
                // 4xx 不重试
                if (400...499).contains(http.statusCode) {
                    throw lastError!
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }

            if attempt < backoffs.count {
                // 用 try 而非 try?：让 cancel 立即抛 CancellationError，循环立即退出，
                // 避免用户切 endpoint / disable cloud sync 后还在后台跑 21s 退避。
                try await Task.sleep(nanoseconds: backoffs[attempt] * 1_000_000_000)
            }
        }

        throw lastError ?? CloudSyncError.invalidResponse
    }

    func testConnection(endpointURLString: String, token: String) async throws {
        let request = try makeRequest(
            endpointURLString: endpointURLString,
            path: "/v1/health",
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            method: "GET"
        )

        try await send(request: request, body: nil)
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
            path: "/v1/quota-samples?limit=\(limit)",
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

    private func send(request: URLRequest, body: Data?) async throws {
        var request = request
        request.httpBody = body

        _ = try await data(for: request)
    }

    private func data(for request: URLRequest) async throws -> Data {
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

private struct CloudRemoteDevice: Decodable {
    let id: String
    let createdAt: String
    let lastSeenAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
    }
}

private struct CloudRemoteQuotaSample: Decodable {
    let provider: String
    let accountName: String?
    let modelName: String
    let currentIntervalTotal: Int
    let currentIntervalRemaining: Int
    let resetEndTime: String?
    let sampledAt: String

    var remainingPercentageText: String {
        guard currentIntervalTotal > 0 else { return "" }
        let percentage = Double(currentIntervalRemaining) / Double(currentIntervalTotal) * 100
        return String(format: "%.1f%%", percentage)
    }

    enum CodingKeys: String, CodingKey {
        case provider
        case accountName = "account_name"
        case modelName = "model_name"
        case currentIntervalTotal = "current_interval_total"
        case currentIntervalRemaining = "current_interval_remaining"
        case resetEndTime = "reset_end_time"
        case sampledAt = "sampled_at"
    }
}

struct CloudUsageSnapshotPayload: Codable {
    let deviceID: String
    let sampledAt: Date
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
    let weeklyTotal: Int
    let weeklyRemaining: Int
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
        self.currentIntervalTotal = model.currentIntervalTotal
        self.currentIntervalRemaining = model.currentIntervalRemaining
        self.weeklyTotal = model.weeklyTotal
        self.weeklyRemaining = model.weeklyRemaining
        self.resetStartTime = model.startTime
        self.resetEndTime = model.endTime
        self.weeklyStartTime = model.weeklyStartTime
        self.weeklyEndTime = model.weeklyEndTime
        self.valueSuffix = model.valueSuffix
        self.detailText = model.detailText
    }
}
