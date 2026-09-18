import Foundation

public struct UsageIdentity: Codable, Equatable, Sendable {
    public let team_id: String
    public let member_id: String
    public let member_name: String
    public let device_id: String
    public var bindingID: String { usageDigest("\(team_id)|\(member_id)|\(device_id)") }
}
public struct UsageIdentityResponse: Codable, Sendable {
    public let identity: UsageIdentity
    public let prices: [UsagePrice]
}
public struct UsageReceipt: Codable, Sendable {
    public struct Rejection: Codable, Sendable { public let id: String; public let reason: String }
    public let accepted: [String]
    public let rejected: [Rejection]
}
public struct TeamUsageRow: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let memberID: String?
    public let records: Int
    public let input: Int64
    public let output: Int64
    public let cached: Int64
    public let cacheWrite: Int64
    public let reasoning: Int64
    public let estimatedRecords: Int
    public let pricedRecords: Int
    public let costUSD: Double
    public let cacheHitRate: Double?
}

public final class UsageClient: @unchecked Sendable {
    private let session: URLSession
    private let endpoint: URL
    private let token: String
    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    public init(endpoint: String, token: String, session: URLSession? = nil) throws {
        guard let url = URL(string: endpoint), let host = url.host, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)),
              !token.isEmpty, !token.contains("\n") else { throw UsageFailure.invalid("Use an HTTPS server origin and a device token") }
        self.endpoint = url; self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.urlCache = nil
        self.session = session ?? URLSession(configuration: config, delegate: RedirectBlocker(), delegateQueue: nil)
    }
    public func identity() async throws -> UsageIdentityResponse {
        let value: UsageIdentityResponse = try await request(path: "/v1/usage/identity")
        try UsagePrice.validate(value.prices)
        return value
    }
    public func send(_ events: [LocalUsageEvent]) async throws -> UsageReceipt {
        struct Batch: Encodable { let events: [LocalUsageEvent] }
        let value: UsageReceipt = try await request(path: "/v1/usage/events/batch", body: JSONEncoder().encode(Batch(events: events)))
        let sent = Set(events.map(\.id))
        let all = value.accepted + value.rejected.map(\.id)
        guard Set(all) == sent, all.count == sent.count else { throw UsageFailure.invalid("Server acknowledgement does not match the batch") }
        return value
    }
    public func summary(from: Date, to: Date, group: String, member: String? = nil) async throws -> [TeamUsageRow] {
        struct Response: Decodable { let groups: [TeamUsageRow] }
        var query = [URLQueryItem(name: "from", value: UsageTime.string(from)), URLQueryItem(name: "to", value: UsageTime.string(to)), URLQueryItem(name: "group_by", value: group)]
        if let member { query.append(URLQueryItem(name: "member_id", value: member)) }
        let value: Response = try await request(path: "/v1/usage/summary", query: query)
        return value.groups
    }
    private func request<T: Decodable>(path: String, body: Data? = nil, query: [URLQueryItem] = []) async throws -> T {
        var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        parts.path = path; parts.queryItems = query.isEmpty ? nil : query
        var req = URLRequest(url: parts.url!)
        req.timeoutInterval = 30; req.httpMethod = body == nil ? "GET" : "POST"; req.httpBody = body
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw UsageFailure.invalid("Invalid usage server response") }
        guard (200...299).contains(http.statusCode) else {
            throw UsageFailure.invalid(http.statusCode == 401 ? "Device credential expired or revoked (401)" : "Usage sync HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
