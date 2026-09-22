import CodexBarCore
import Foundation

struct KimiWebUsageClient {
    let session: URLSession
    private static let defaultSession = URLSession(configuration: .ephemeral,
                                                    delegate: NoRedirects(), delegateQueue: nil)
    init(session: URLSession? = nil) { self.session = session ?? Self.defaultSession }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    func fetch(_ credential: KimiWebSession) async throws -> UsageSnapshot {
        let credential = try credential.validated()
        // Membership enrichment is optional and bounded independently of Code quota.
        async let statsData = optionalStats(credential)
        let usageData = try await request(
            "kimi.gateway.billing.v1.BillingService/GetUsages",
            body: Data(#"{"scope":["FEATURE_CODING"]}"#.utf8), credential: credential)
        let stats = await statsData
        try Task.checkCancellation()
        return try Self.parse(usageData, stats: stats)
    }

    private func optionalStats(_ credential: KimiWebSession) async -> Data? {
        try? await request("kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats",
                           body: Data("{}".utf8), credential: credential, timeout: 3)
    }

    private func request(_ method: String, body: Data, credential: KimiWebSession,
                         timeout: TimeInterval = 20) async throws -> Data {
        var request = URLRequest(url: URL(string: credential.origin + "/apiv2/" + method)!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("kimi-auth=\(credential.token)", forHTTPHeaderField: "Cookie")
        request.setValue(credential.origin, forHTTPHeaderField: "Origin")
        request.setValue(credential.origin + "/code/console", forHTTPHeaderField: "Referer")
        request.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageError.invalidResponse }
        // Do not include response bodies or authentication headers in errors/logs.
        if http.statusCode == 401 || http.statusCode == 403 { throw KimiSessionError.expired }
        guard http.statusCode == 200 else { throw UsageError.apiError("Kimi HTTP \(http.statusCode)") }
        return data
    }

    static func parse(_ data: Data, stats: Data? = nil, now: Date = Date()) throws -> UsageSnapshot {
        let response = try JSONDecoder().decode(Usages.self, from: data)
        let coding = response.usages.first(where: { $0.scope == "FEATURE_CODING" })
        let weekly = coding.flatMap { window($0.detail, minutes: 7 * 24 * 60) }
        let limit = coding?.limits?.first(where: { $0.window?.minutes == 300 }) ?? coding?.limits?.first
        let short = limit.flatMap { window($0.detail, minutes: $0.window?.minutes) }
        var extras: [NamedRateWindow] = []
        if let stats, let membership = try? JSONDecoder().decode(Stats.self, from: stats) {
            if let balance = membership.subscriptionBalance,
               balance.feature == nil || balance.feature == "FEATURE_OMNI",
               balance.type == nil || balance.type == "SUBSCRIPTION",
               let ratio = balance.amountUsedRatio, ratio.isFinite, ratio >= 0 {
                extras.append(NamedRateWindow(id: "kimi-monthly", title: "Total usage",
                    window: RateWindow(usedPercent: min(1, ratio) * 100, windowMinutes: nil,
                                       resetsAt: date(balance.expireTime), resetDescription: nil)))
            }
        }
        guard weekly != nil || short != nil || !extras.isEmpty else { throw UsageError.invalidResponse }
        return UsageSnapshot(primary: weekly, secondary: short, extraRateWindows: extras,
                             updatedAt: now)
    }

    private static func window(_ detail: KimiUsageDetail, minutes: Int?) -> RateWindow? {
        guard let total = Double(detail.limit), total.isFinite, total > 0 else { return nil }
        let used: Double
        if let raw = detail.used, let value = Double(raw), value.isFinite, value >= 0 {
            used = value
        } else if let raw = detail.remaining, let value = Double(raw), value.isFinite,
                  (0...total).contains(value) {
            used = total - value
        } else { return nil }
        return RateWindow(usedPercent: min(100, used / total * 100), windowMinutes: minutes,
                          resetsAt: date(detail.resetTime), resetDescription: nil)
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private struct Usages: Decodable { let usages: [Usage] }
    private struct Usage: Decodable {
        let scope: String
        let detail: KimiUsageDetail
        let limits: [Limit]?
    }
    private struct Limit: Decodable { let detail: KimiUsageDetail; let window: Window? }
    private struct Window: Decodable {
        let duration: Int
        let timeUnit: String
        var minutes: Int? {
            let multiplier: Int
            switch timeUnit {
            case "TIME_UNIT_MINUTE": multiplier = 1
            case "TIME_UNIT_HOUR": multiplier = 60
            case "TIME_UNIT_DAY": multiplier = 1440
            default: return nil
            }
            let (result, overflow) = duration.multipliedReportingOverflow(by: multiplier)
            return !overflow && result > 0 ? result : nil
        }
    }
    private struct Stats: Decodable { let subscriptionBalance: Balance? }
    private struct Balance: Decodable {
        let feature: String?
        let type: String?
        let amountUsedRatio: Double?
        let expireTime: String?
    }
}
