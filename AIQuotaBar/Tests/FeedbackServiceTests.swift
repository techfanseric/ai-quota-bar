import XCTest
@testable import AIQuotaBar

@MainActor
final class FeedbackServiceTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedbackStubProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        FeedbackStubProtocol.reset([])
        super.tearDown()
    }

    private func makeService() -> FeedbackService {
        FeedbackService(session: session, endpointURLString: "https://test.invalid", token: "test-token")
    }

    func testSubmitBuildsRequestAndDecodesSuccess() async throws {
        FeedbackStubProtocol.reset([.http(200, #"{"ok":true,"id":"f0123456789abcdef"}"#)])
        let result = try await makeService().submit(nickname: "小明", message: "很好用", contact: "ming@example.com")
        XCTAssertEqual(result.id, "f0123456789abcdef")

        let request = try XCTUnwrap(FeedbackStubProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://test.invalid/v1/feedback")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(FeedbackStubProtocol.lastBody)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(payload["nickname"], "小明")
        XCTAssertEqual(payload["message"], "很好用")
        XCTAssertEqual(payload["contact"], "ming@example.com")
        XCTAssertNotNil(payload["appVersion"])
        XCTAssertNotNil(payload["osVersion"])
    }

    func testSubmitTrimsFieldsBeforeSending() async throws {
        FeedbackStubProtocol.reset([.http(200, #"{"ok":true,"id":"f0123456789abcdef"}"#)])
        _ = try await makeService().submit(nickname: "  小明  ", message: "  留言  ", contact: " ")
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: FeedbackStubProtocol.lastBody!) as? [String: String])
        XCTAssertEqual(payload["nickname"], "小明")
        XCTAssertEqual(payload["message"], "留言")
        XCTAssertEqual(payload["contact"], "")
    }

    func testErrorStatusesMapToDistinctCases() async {
        let cases: [(Int, FeedbackSubmitError)] = [
            (400, .invalidContent),
            (413, .invalidContent),
            (429, .rateLimited),
            (500, .serverUnavailable),
            (503, .serverUnavailable),
        ]
        for (status, expected) in cases {
            FeedbackStubProtocol.reset([.http(status, #"{"error":"x"}"#)])
            do {
                _ = try await makeService().submit(nickname: "", message: "留言", contact: "")
                XCTFail("expected error for status \(status)")
            } catch let error as FeedbackSubmitError {
                XCTAssertEqual(error, expected, "status \(status)")
            } catch {
                XCTFail("unexpected error type for status \(status): \(error)")
            }
        }
    }

    func testMalformedSuccessBodyFailsClosed() async {
        FeedbackStubProtocol.reset([.http(200, #"{"ok":false}"#)])
        do {
            _ = try await makeService().submit(nickname: "", message: "留言", contact: "")
            XCTFail("expected error")
        } catch let error as FeedbackSubmitError {
            XCTAssertEqual(error, .serverUnavailable)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testLocalValidationRejectsInvalidInputWithoutRequest() async {
        FeedbackStubProtocol.reset([])
        let service = makeService()
        for (nickname, message, contact, expected) in [
            ("", "  \n ", "", FeedbackSubmitError.emptyMessage),
            ("", String(repeating: "长", count: 1001), "", FeedbackSubmitError.messageTooLong),
            (String(repeating: "名", count: 31), "留言", "", FeedbackSubmitError.invalidContent),
            ("", "留言", String(repeating: "c", count: 121), FeedbackSubmitError.invalidContent),
        ] {
            do {
                _ = try await service.submit(nickname: nickname, message: message, contact: contact)
                XCTFail("expected \(expected) for nickname=\(nickname.count) message=\(message.count) contact=\(contact.count)")
            } catch let error as FeedbackSubmitError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("unexpected error type: \(error)")
            }
        }
        XCTAssertNil(FeedbackStubProtocol.lastRequest)
    }

    func testNetworkErrorsMapToFriendlyMessages() async {
        FeedbackStubProtocol.reset([.network(.notConnectedToInternet)])
        do {
            _ = try await makeService().submit(nickname: "", message: "留言", contact: "")
            XCTFail("expected error")
        } catch let error as FeedbackSubmitError {
            guard case .network(let message) = error else {
                return XCTFail("expected .network, got \(error)")
            }
            XCTAssertFalse(message.isEmpty)
            XCTAssertNotNil(error.errorDescription)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}

private final class FeedbackStubProtocol: URLProtocol {
    enum Reply {
        case http(Int, String)
        case network(URLError.Code)
    }

    private static let lock = NSLock()
    private static var replies: [Reply] = []
    static var lastRequest: URLRequest?
    static var lastBody: Data?

    static func reset(_ newReplies: [Reply]) {
        lock.lock()
        defer { lock.unlock() }
        replies = newReplies
        lastRequest = nil
        lastBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 64 * 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
        let reply = Self.replies.isEmpty ? Reply.http(599, "unexpected request") : Self.replies.removeFirst()
        Self.lock.unlock()
        switch reply {
        case let .http(status, body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case let .network(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}
