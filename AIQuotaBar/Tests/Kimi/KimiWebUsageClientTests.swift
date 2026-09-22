import CodexBarCore
import XCTest
@testable import AIQuotaBar

final class KimiWebUsageClientTests: XCTestCase {
    private func client(status: Int = 200) -> KimiWebUsageClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QuotaProtocol.self]
        config.httpAdditionalHeaders = ["X-Test-Status": String(status)]
        let session = URLSession(configuration: config)
        addTeardownBlock { session.invalidateAndCancel() }
        return KimiWebUsageClient(session: session)
    }

    func testOptionalMembershipFailurePreservesQuotaAndRegion() async throws {
        let snapshot = try await client().fetch(KimiWebSession(token: "fixture-only", origin: "https://www.kimi.ai"))
        XCTAssertEqual(snapshot.primary?.remainingPercent, 60)
        XCTAssertTrue(snapshot.extraRateWindows?.isEmpty == true)
    }

    func testAuthenticationFailureDoesNotExposeResponseBody() async {
        do {
            _ = try await client(status: 401).fetch(KimiWebSession(token: "fixture-only", origin: "https://www.kimi.ai"))
            XCTFail("Expected expired login")
        } catch {
            XCTAssertTrue(error is KimiSessionError)
            XCTAssertFalse(error.localizedDescription.contains("sensitive-response"))
        }
    }

    func testHTTPErrorDoesNotExposeResponseBody() async {
        do {
            _ = try await client(status: 429).fetch(KimiWebSession(token: "fixture-only", origin: "https://www.kimi.ai"))
            XCTFail("Expected HTTP error")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("sensitive-response"))
        }
    }

    private final class QuotaProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            XCTAssertEqual(request.url?.host, "www.kimi.ai")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-only")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://www.kimi.ai")
            XCTAssertEqual(request.httpMethod, "POST")
            let isUsage = request.url!.path.hasSuffix("GetUsages")
            let status = isUsage ? Int(request.value(forHTTPHeaderField: "X-Test-Status") ?? "200")! : 503
            let data = status == 200
                ? Data(#"{"usages":[{"scope":"FEATURE_CODING","detail":{"limit":100,"remaining":60}}]}"#.utf8)
                : Data("sensitive-response".utf8)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
}
