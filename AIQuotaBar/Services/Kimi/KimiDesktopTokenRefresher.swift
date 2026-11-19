import Foundation

/// Keeps a renewed Kimi Desktop access token in memory so repeated polls do
/// not each have to renew it.
///
/// Kimi's own token store keeps a short-lived access token, so without this
/// cache every refresh would send one renewal request. The renewed token
/// lives only in this process: nothing is written to Kimi's store, its
/// Keychain entry, or any cookie database.
final class KimiDesktopTokenCache: @unchecked Sendable {
    static let shared = KimiDesktopTokenCache()

    private struct Entry {
        let accessToken: String
        let expiry: Date?
        /// The account the token belongs to, so a renewal for one Kimi
        /// account can never be served for another.
        let accountID: String?
        let origin: String
    }

    private let lock = NSLock()
    private var entry: Entry?

    func token(accountID: String?, origin: String, now: Date = Date()) -> String? {
        lock.withLock {
            guard let entry else { return nil }
            guard entry.origin == origin else { return nil }
            guard entry.accountID == accountID else { return nil }
            // Treat a token that is about to expire as absent.
            if let expiry = entry.expiry, expiry <= now.addingTimeInterval(60) { return nil }
            return entry.accessToken
        }
    }

    func store(_ token: String, accountID: String?, origin: String, expiry: Date?) {
        lock.withLock {
            entry = Entry(
                accessToken: token,
                expiry: expiry,
                accountID: accountID,
                origin: origin)
        }
    }

    func clear() {
        lock.withLock { entry = nil }
    }
}

/// Renews the Kimi Desktop access token from the refresh token the desktop
/// client already stored on disk.
///
/// The desktop client's `access_token` is short-lived (15 minutes) while its
/// `refresh_token` stays valid for months. Kimi only rewrites the store when
/// the client itself is running and talking to its own API, so a token that
/// was left behind when the client last quit expires within minutes and every
/// later quota read fails with HTTP 401.
///
/// Refreshing is deliberately conservative:
///
/// * The desktop `refresh_token` is **not** rotated by the server — the
///   response hands back the same token, so the desktop client's own stored
///   credential keeps working and is never invalidated by us.
/// * Only the account's own region is contacted. The origin comes from the
///   token store itself; a foreign region answers 403 and would count as a
///   credential probe, so it is never tried.
/// * Nothing is written to the Kimi store, the Kimi Keychain entry, or any
///   cookie database. The renewed access token lives in memory only.
/// * The refresh token and the access token are never logged or included in
///   error messages.
struct KimiDesktopTokenRefresher: Sendable {
    struct Refreshed: Sendable, Equatable {
        let accessToken: String
        let origin: String
        /// When the renewed token expires, when the server says so.
        let expiry: Date?
        /// The Kimi account the token belongs to.
        let accountID: String?
    }

    enum RefreshError: LocalizedError, Sendable, Equatable {
        case missingRefreshToken
        case rejected
        case invalidResponse
        case unsupportedOrigin

        var errorDescription: String? {
            if AppLanguage.current == .simplifiedChinese {
                switch self {
                case .missingRefreshToken: return "Kimi 桌面登录缺少续期凭证，请在 Kimi 中重新登录。"
                case .rejected: return "Kimi 桌面登录已失效，请在 Kimi 中重新登录。"
                case .invalidResponse: return "Kimi 桌面登录续期响应无法解析。"
                case .unsupportedOrigin: return "不支持此 Kimi 登录站点。"
                }
            }
            switch self {
            case .missingRefreshToken: return "The Kimi Desktop sign-in has no refresh credential. Sign in again in Kimi."
            case .rejected: return "The Kimi Desktop sign-in expired. Sign in again in Kimi."
            case .invalidResponse: return "The Kimi Desktop renewal response could not be parsed."
            case .unsupportedOrigin: return "The Kimi sign-in origin is unsupported."
            }
        }
    }

    /// The desktop client's own refresh endpoint. The path mirrors what the
    /// shipped Kimi app calls; the region host comes from the token store.
    static let refreshPath = "/api/auth/token/refresh"

    let session: URLSession
    private static let defaultSession = URLSession(configuration: .ephemeral,
                                                    delegate: NoRedirects(), delegateQueue: nil)

    init(session: URLSession? = nil) {
        self.session = session ?? Self.defaultSession
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    /// Renews `accessToken` using `refreshToken`.
    ///
    /// The origin is validated against the two known Kimi web origins, so a
    /// tampered store cannot redirect the refresh token to another host.
    func refresh(refreshToken: String, origin: String) async throws -> Refreshed {
        let trimmed = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        // The server prefixes the returned refresh token with "Bearer ". The
        // stored value does not carry it, so strip it before comparing.
        let normalized = trimmed.hasPrefix("Bearer ") ? String(trimmed.dropFirst("Bearer ".count)) : trimmed
        guard !normalized.isEmpty else { throw RefreshError.missingRefreshToken }
        guard ["https://www.kimi.com", "https://www.kimi.ai"].contains(origin) else {
            throw RefreshError.unsupportedOrigin
        }

        var request = URLRequest(url: URL(string: origin + Self.refreshPath)!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(normalized)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN", forHTTPHeaderField: "X-Language")
        request.setValue(origin, forHTTPHeaderField: "Origin")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RefreshError.invalidResponse }
        // Never surface the response body: it carries tokens.
        guard http.statusCode == 200 else { throw RefreshError.rejected }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw RefreshError.invalidResponse
        }
        let accessToken = payload.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else { throw RefreshError.invalidResponse }
        return Refreshed(
            accessToken: accessToken,
            origin: origin,
            expiry: Self.expiry(of: accessToken),
            accountID: Self.accountID(of: accessToken))
    }

    private struct Payload: Decodable {
        let accessToken: String
        let refreshToken: String?

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
        }
    }

    /// Reads the `exp` claim so a cached token can be dropped before it
    /// actually expires.
    static func expiry(of token: String) -> Date? {
        guard let claims = claims(of: token) else { return nil }
        return (claims["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
    }

    /// Reads the `sub` claim so a renewed token is only reused for the account
    /// it was issued for.
    static func accountID(of token: String) -> String? {
        guard let claims = claims(of: token) else { return nil }
        return claims["sub"] as? String
    }

    private static func claims(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
