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

final class CloudSyncService {
    static let shared = CloudSyncService()

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init(session: URLSession = .shared) {
        self.session = session
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        // server 端 worker 实际写入的是 `2024-01-01T12:34:56.789Z` / `2024-01-01T12:34:56Z` 两种
        // 变体；用自定义 .custom 比 .iso8601 strategy 更鲁棒
        self.decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = CloudSyncService.parseISODate(raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized ISO8601 date: \(raw)")
        }
    }

    func syncUsageData(_ usageData: UsageData, sampledAt: Date) async throws {
        let settings = CloudSyncSettings.current
        guard settings.isEnabled else { throw CloudSyncError.disabled }

        let token = KeychainService.shared.getCloudSyncToken()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { throw CloudSyncError.missingToken }

        let request = try makeRequest(
            endpointURLString: settings.endpointURLString,
            path: "/v1/quota-samples",
            token: token,
            method: "POST"
        )

        let payload = CloudUsageSnapshotPayload(
            deviceID: settings.deviceID,
            sampledAt: sampledAt,
            models: usageData.models.map { CloudModelQuotaPayload(model: $0) }
        )

        try await send(request: request, body: try encoder.encode(payload))
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

    /// 拉取最近 N 条云端 quota 样本（worker 端按时间倒序返回），按 `ModelUsageData.id`
    /// 同款格式分组成 `[modelID: [ModelQuotaSample]]`，供 chart 历史回填。
    /// server 不支持 `?since=` / `?modelId=`，所以一次拉全量在客户端过滤。
    func fetchRecentQuotaSamples(limit: Int) async throws -> [String: [ModelQuotaSample]] {
        let settings = CloudSyncSettings.current
        guard settings.isEnabled else { throw CloudSyncError.disabled }

        let token = KeychainService.shared.getCloudSyncToken()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { throw CloudSyncError.missingToken }

        let request = try makeRequest(
            endpointURLString: settings.endpointURLString,
            path: "/v1/quota-samples?limit=\(limit)",
            token: token,
            method: "GET"
        )

        let response = try decoder.decode(CloudQuotaSamplesResponse.self, from: try await data(for: request))

        var grouped: [String: [ModelQuotaSample]] = [:]
        for sample in response.samples {
            guard let provider = UsageProvider(rawValue: sample.provider) else { continue }
            let modelID = ModelUsageData.makeID(
                provider: provider,
                accountName: sample.accountName,
                modelName: sample.modelName
            )
            let quotaSample = ModelQuotaSample(
                timestamp: sample.sampledAt,
                remaining: sample.currentIntervalRemaining,
                percent: nil
            )
            grouped[modelID, default: []].append(quotaSample)
        }
        return grouped
    }

    /// 容错的 ISO8601 解析：worker / 不同 SDK 输出的格式略有不同。
    private static let iso8601Formatters: [ISO8601DateFormatter] = {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return [withFractional, basic]
    }()

    static func parseISODate(_ raw: String) -> Date? {
        for formatter in iso8601Formatters {
            if let date = formatter.date(from: raw) {
                return date
            }
        }
        return nil
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
              <td>\(escapeHTML(sample.sampledAtDisplayString))</td>
              <td>\(escapeHTML(sample.provider))</td>
              <td>\(escapeHTML(sample.accountName ?? ""))</td>
              <td>\(escapeHTML(sample.modelName))</td>
              <td>\(sample.currentIntervalRemaining)</td>
              <td>\(sample.currentIntervalTotal)</td>
              <td>\(escapeHTML(sample.remainingPercentageText))</td>
              <td>\(escapeHTML(sample.resetEndTimeDisplayString))</td>
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
    let resetEndTime: Date?
    let sampledAt: Date

    var remainingPercentageText: String {
        guard currentIntervalTotal > 0 else { return "" }
        let percentage = Double(currentIntervalRemaining) / Double(currentIntervalTotal) * 100
        return String(format: "%.1f%%", percentage)
    }

    var sampledAtDisplayString: String {
        CloudSyncService.displayDateFormatter.string(from: sampledAt)
    }

    var resetEndTimeDisplayString: String {
        guard let resetEndTime else { return "" }
        return CloudSyncService.displayDateFormatter.string(from: resetEndTime)
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

private extension CloudSyncService {
    static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}

private struct CloudUsageSnapshotPayload: Encodable {
    let deviceID: String
    let sampledAt: Date
    let models: [CloudModelQuotaPayload]
}

private struct CloudModelQuotaPayload: Encodable {
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
