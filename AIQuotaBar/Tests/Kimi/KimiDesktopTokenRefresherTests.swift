import Foundation
import XCTest
@testable import AIQuotaBar

final class KimiDesktopTokenRefresherTests: XCTestCase {
    func testRenewalUsesTheAccountsOwnOriginAndReturnsTheAccessToken() async throws {
        let session = makeSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://www.kimi.com/api/auth/token/refresh")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer refresh-fixture")
            return (200, #"{"access_token":"renewed-token","refresh_token":"Bearer refresh-fixture"}"#)
        }
        let refreshed = try await KimiDesktopTokenRefresher(session: session).refresh(
            refreshToken: "refresh-fixture", origin: "https://www.kimi.com")
        XCTAssertEqual(refreshed.accessToken, "renewed-token")
        XCTAssertEqual(refreshed.origin, "https://www.kimi.com")
    }

    func testBearerPrefixedRefreshTokenIsAccepted() async throws {
        let session = makeSession { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer refresh-fixture")
            return (200, #"{"access_token":"renewed-token"}"#)
        }
        let refreshed = try await KimiDesktopTokenRefresher(session: session).refresh(
            refreshToken: "Bearer refresh-fixture", origin: "https://www.kimi.com")
        XCTAssertEqual(refreshed.accessToken, "renewed-token")
    }

    func testForeignOriginIsRejectedWithoutANetworkRequest() async throws {
        let session = makeSession { _ in
            XCTFail("A foreign origin must never be contacted")
            return (200, "{}")
        }
        do {
            _ = try await KimiDesktopTokenRefresher(session: session).refresh(
                refreshToken: "refresh-fixture", origin: "https://evil.test")
            XCTFail("Expected an unsupported origin")
        } catch {
            XCTAssertEqual(error as? KimiDesktopTokenRefresher.RefreshError,
                           .unsupportedOrigin)
        }
    }

    func testMissingRefreshTokenFailsWithoutANetworkRequest() async throws {
        let session = makeSession { _ in
            XCTFail("An empty refresh token must never be sent")
            return (200, "{}")
        }
        do {
            _ = try await KimiDesktopTokenRefresher(session: session).refresh(
                refreshToken: "   ", origin: "https://www.kimi.com")
            XCTFail("Expected a missing refresh token")
        } catch {
            XCTAssertEqual(error as? KimiDesktopTokenRefresher.RefreshError,
                           .missingRefreshToken)
        }
    }

    func testRejectedRenewalDoesNotLeakTheResponseBody() async throws {
        let session = makeSession { _ in (401, #"{"token":"sensitive-response"}"#) }
        do {
            _ = try await KimiDesktopTokenRefresher(session: session).refresh(
                refreshToken: "refresh-fixture", origin: "https://www.kimi.com")
            XCTFail("Expected the renewal to be rejected")
        } catch {
            XCTAssertEqual(error as? KimiDesktopTokenRefresher.RefreshError, .rejected)
            XCTAssertFalse(error.localizedDescription.contains("sensitive-response"))
        }
    }

    func testMalformedRenewalResponseFails() async throws {
        let session = makeSession { _ in (200, "not-json") }
        do {
            _ = try await KimiDesktopTokenRefresher(session: session).refresh(
                refreshToken: "refresh-fixture", origin: "https://www.kimi.com")
            XCTFail("Expected an invalid response")
        } catch {
            XCTAssertEqual(error as? KimiDesktopTokenRefresher.RefreshError,
                           .invalidResponse)
        }
    }

    func testEmptyAccessTokenFails() async throws {
        let session = makeSession { _ in (200, #"{"access_token":""}"#) }
        do {
            _ = try await KimiDesktopTokenRefresher(session: session).refresh(
                refreshToken: "refresh-fixture", origin: "https://www.kimi.com")
            XCTFail("Expected an invalid response")
        } catch {
            XCTAssertEqual(error as? KimiDesktopTokenRefresher.RefreshError,
                           .invalidResponse)
        }
    }

    private func makeSession(
        handler: @escaping (URLRequest) -> (Int, String)
    ) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RenewalProtocol.self]
        let session = URLSession(configuration: config)
        RenewalProtocol.handler = handler
        addTeardownBlock {
            session.invalidateAndCancel()
            RenewalProtocol.handler = nil
        }
        return session
    }

    private final class RenewalProtocol: URLProtocol {
        static var handler: ((URLRequest) -> (Int, String))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let (status, body) = handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }
}
