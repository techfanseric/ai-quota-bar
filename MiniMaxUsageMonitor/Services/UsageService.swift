import Foundation

/// Service for fetching MiniMax API usage data
final class UsageService {
    static let shared = UsageService()

    private let apiURL = "https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains"

    private init() {}

    private func authorizationHeaderValue(for apiKey: String) -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKey.lowercased().hasPrefix("bearer ") {
            return trimmedKey
        }
        return "Bearer \(trimmedKey)"
    }

    private func decodeUsageData(from data: Data) throws -> UsageData {
        let decoder = JSONDecoder()
        let response = try decoder.decode(MiniMaxUsageAPIResponse.self, from: data)

        guard response.baseResp.statusCode == 0 else {
            throw UsageError.apiError(response.baseResp.statusMessage)
        }

        let total = response.modelRemains.reduce(0) { $0 + $1.currentIntervalTotalCount }
        let used = response.modelRemains.reduce(0) { $0 + $1.currentIntervalUsageCount }
        let remains = max(0, total - used)

        return UsageData(remains: remains, total: max(total, 1), timestamp: Date())
    }

    /// Fetch current usage data from MiniMax API
    func fetchUsage() async throws -> UsageData {
        guard let apiKey = KeychainService.shared.getAPIKey() else {
            throw UsageError.notConfigured
        }

        guard let url = URL(string: apiURL) else {
            throw UsageError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(authorizationHeaderValue(for: apiKey), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let language = AppLanguage.current
            let message = String(data: data, encoding: .utf8) ?? language.text(.unknownError)
            throw UsageError.apiError(language.apiStatusMessage(statusCode: httpResponse.statusCode, message: message))
        }

        do {
            return try decodeUsageData(from: data)
        } catch let usageError as UsageError {
            throw usageError
        } catch {
            throw UsageError.invalidResponse
        }
    }

    /// Test API connection with given key
    func testConnection(apiKey: String) async throws -> Bool {
        guard let url = URL(string: apiURL) else {
            throw UsageError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(authorizationHeaderValue(for: apiKey), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            return false
        }

        do {
            _ = try decodeUsageData(from: data)
            return true
        } catch {
            return false
        }
    }
}
