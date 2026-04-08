import Foundation

/// Service for fetching MiniMax API usage data
final class UsageService {
    static let shared = UsageService()

    private let apiURL = "https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains"

    private init() {}

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
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
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
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw UsageError.apiError("Status \(httpResponse.statusCode): \(message)")
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(UsageData.self, from: data)
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
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageError.invalidResponse
        }

        return (200...299).contains(httpResponse.statusCode)
    }
}