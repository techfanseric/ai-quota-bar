import Foundation

enum FeedbackSubmitError: LocalizedError, Equatable {
    case emptyMessage
    case messageTooLong
    case invalidContent
    case rateLimited
    case serverUnavailable
    case network(String)

    var errorDescription: String? {
        let chinese = AppLanguage.current == .simplifiedChinese
        switch self {
        case .emptyMessage:
            return chinese ? "请先写下留言内容。" : "Write your message first."
        case .messageTooLong:
            return chinese ? "留言不能超过 1000 字，请精简后重试。" : "Message must be 1000 characters or fewer."
        case .invalidContent:
            return chinese ? "反馈内容不符合要求，请检查昵称与联系方式后重试。" : "Feedback content is invalid; check the nickname and contact info."
        case .rateLimited:
            return chinese ? "提交过于频繁，请 1 小时后再试。" : "Submitting too often; try again in an hour."
        case .serverUnavailable:
            return chinese ? "反馈服务暂不可用，请稍后重试。" : "Feedback service is unavailable; try again later."
        case .network(let message):
            return message
        }
    }

    static func networkMessage(for error: Error) -> FeedbackSubmitError {
        let chinese = AppLanguage.current == .simplifiedChinese
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed:
                return .network(chinese ? "网络未连接，请联网后重试。" : "No network connection; connect and try again.")
            case .timedOut:
                return .network(chinese ? "连接超时，请稍后重试。" : "The connection timed out; try again later.")
            case .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return .network(chinese ? "网络连接失败，请检查网络后重试。" : "Network connection failed; check your network and try again.")
            default:
                break
            }
        }
        return .network(chinese ? "网络错误，请稍后重试。" : "Network error; try again later.")
    }
}

/// Posts feedback from the About tab to the public feedback wall. The message
/// is published immediately; contact info is only visible in the operator
/// console, never on the website.
@MainActor
final class FeedbackService {
    static let shared = FeedbackService()

    static let messageLimit = 1000
    static let nicknameLimit = 30
    static let contactLimit = 120

    struct SubmitResult: Equatable {
        let id: String
    }

    private let session: URLSession
    private let endpointURLString: String
    private let token: String

    init(session: URLSession = .shared,
         endpointURLString: String = CloudSyncSettings.defaultEndpointURLString,
         token: String = CloudSyncSettings.defaultServiceToken) {
        self.session = session
        self.endpointURLString = endpointURLString
        self.token = token
    }

    func submit(nickname: String, message: String, contact: String) async throws -> SubmitResult {
        let trimmedNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContact = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { throw FeedbackSubmitError.emptyMessage }
        guard trimmedMessage.count <= Self.messageLimit else { throw FeedbackSubmitError.messageTooLong }
        guard trimmedNickname.count <= Self.nicknameLimit, trimmedContact.count <= Self.contactLimit else {
            throw FeedbackSubmitError.invalidContent
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let payload: [String: String] = [
            "nickname": trimmedNickname,
            "message": trimmedMessage,
            "contact": trimmedContact,
            "appVersion": UpdateChecker.currentAppVersion,
            "osVersion": "\(os.majorVersion).\(os.minorVersion)",
        ]
        guard let url = URL(string: endpointURLString + "/v1/feedback") else {
            throw FeedbackSubmitError.serverUnavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AIQuotaBar", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FeedbackSubmitError.networkMessage(for: error)
        }
        guard let http = response as? HTTPURLResponse else { throw FeedbackSubmitError.serverUnavailable }
        switch http.statusCode {
        case 200:
            struct SubmitResponse: Decodable {
                let ok: Bool
                let id: String?
            }
            guard let decoded = try? JSONDecoder().decode(SubmitResponse.self, from: data), decoded.ok,
                  let id = decoded.id else { throw FeedbackSubmitError.serverUnavailable }
            return SubmitResult(id: id)
        case 400, 413:
            throw FeedbackSubmitError.invalidContent
        case 429:
            throw FeedbackSubmitError.rateLimited
        default:
            throw FeedbackSubmitError.serverUnavailable
        }
    }
}
