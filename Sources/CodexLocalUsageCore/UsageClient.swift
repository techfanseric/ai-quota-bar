import Foundation

public struct UsageIdentity: Codable, Equatable, Sendable {
    public let team_name: String?
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
public struct UsageJoinResponse: Codable, Sendable {
    public let token: String
    public let identity: UsageIdentity
}
public struct UsageTeamCreated: Codable, Sendable {
    public let teamID: String
    public let teamName: String
    public let inviteCode: String
    public let loginPassword: String
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
        self.session = session ?? URLSession(configuration: UsageClient.sessionConfiguration(), delegate: RedirectBlocker(), delegateQueue: nil)
    }
    /// Self-service join: the invite code is the only credential, so this call
    /// never sends an Authorization header. The returned device token feeds the
    /// regular connect flow afterwards.
    public static func join(endpoint: String, inviteCode: String, memberName: String, deviceID: String,
                            memberPassphrase: String? = nil, session: URLSession? = nil) async throws -> UsageJoinResponse {
        guard let url = URL(string: endpoint), let host = url.host, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw UsageFailure.invalid("Use an HTTPS server origin")
        }
        struct Payload: Encodable { let inviteCode: String; let memberName: String; let deviceID: String; let memberPassphrase: String? }
        let trimmed = { (value: String) in value.trimmingCharacters(in: .whitespacesAndNewlines) }
        let passphrase = (memberPassphrase ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Normalize like the server does, so pasted lowercase or spaced codes match.
        let code = String(trimmed(inviteCode).uppercased().filter { $0.isLetter || $0.isNumber })
        var request = URLRequest(url: UsageClient.requestURL(base: url, path: "/v1/usage/join"))
        request.timeoutInterval = 30; request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Payload(inviteCode: code, memberName: trimmed(memberName), deviceID: trimmed(deviceID), memberPassphrase: passphrase.isEmpty ? nil : passphrase))
        let value: UsageJoinResponse = try await perform(request, session: session ?? URLSession(configuration: UsageClient.sessionConfiguration(), delegate: RedirectBlocker(), delegateQueue: nil), join: true)
        guard !value.token.isEmpty, value.identity.device_id == trimmed(deviceID) else { throw UsageFailure.invalid("Server joined a different device") }
        return value
    }
    public static func createTeam(endpoint: String, name: String, session: URLSession? = nil) async throws -> UsageTeamCreated {
        let client = try UsageClient(endpoint: endpoint, token: "create", session: session)
        var request = URLRequest(url: requestURL(base: client.endpoint, path: "/v1/team/create"))
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["teamName": name.trimmingCharacters(in: .whitespacesAndNewlines)])
        return try await perform(request, session: client.session, join: true)
    }
    /// Only a short-lived, one-use ticket enters the URL. Device and manager credentials stay in HTTPS bodies/headers.
    public func teamBrowserURL(managementPassword: String? = nil) async throws -> URL {
        struct Payload: Encodable { let managementPassword: String? }
        struct Ticket: Decodable { let ticket: String; let role: String }
        let value: Ticket = try await request(path: "/v1/team/handoff", body: JSONEncoder().encode(Payload(managementPassword: managementPassword)))
        guard value.ticket.count == 64, value.ticket.allSatisfy({ "0123456789abcdef".contains($0) }),
              value.role == (managementPassword == nil ? "member" : "manager") else {
            throw UsageFailure.invalid("Invalid team sign-in response")
        }
        var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        parts.path = "/team"; parts.fragment = "handoff=" + value.ticket
        return parts.url!
    }
    public func leave() async throws {
        struct Ack: Decodable { let ok: Bool }
        let _: Ack = try await request(path: "/v1/usage/leave", body: Data("{}".utf8))
    }
    public func setMemberPassphrase(_ passphrase: String) async throws {
        struct Payload: Encodable { let passphrase: String }
        struct Ack: Decodable { let ok: Bool }
        let _: Ack = try await request(path: "/v1/usage/member/passphrase", body: try JSONEncoder().encode(Payload(passphrase: passphrase)))
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
        var req = URLRequest(url: UsageClient.requestURL(base: endpoint, path: path, query: query))
        req.timeoutInterval = 30; req.httpMethod = body == nil ? "GET" : "POST"; req.httpBody = body
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await UsageClient.perform(req, session: session)
    }
    private static func requestURL(base: URL, path: String, query: [URLQueryItem] = []) -> URL {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        parts.path = path; parts.queryItems = query.isEmpty ? nil : query
        return parts.url!
    }
    private static func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.urlCache = nil
        return config
    }
    private static func perform<T: Decodable>(_ req: URLRequest, session: URLSession, join: Bool = false) async throws -> T {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw UsageFailure.invalid("Invalid usage server response") }
        guard (200...299).contains(http.statusCode) else {
            if join {
                let reason = [401: "Invalid invite code or member passphrase", 409: "Name taken or device already bound",
                              403: "Team is full", 429: "Too many attempts; retry later"][http.statusCode]
                throw UsageFailure.invalid(reason.map { "\($0) (\(http.statusCode))" } ?? "Team join HTTP \(http.statusCode)")
            }
            throw UsageFailure.invalid(http.statusCode == 401 ? "Device credential expired or revoked (401)" : "Usage sync HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
