import Foundation

/// Service for fetching provider usage data
final class UsageService {
    static let shared = UsageService()

    private let miniMaxAPIURL = "https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains"

    private init() {}

    private func authorizationHeaderValue(for apiKey: String) -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKey.lowercased().hasPrefix("bearer ") {
            return trimmedKey
        }
        return "Bearer \(trimmedKey)"
    }

    func prepareCredentialForStorage(_ credential: String, provider: UsageProvider) throws -> String {
        switch provider {
        case .miniMax:
            return credential.trimmingCharacters(in: .whitespacesAndNewlines)
        case .glm:
            return try GLMCredential.parse(credential).storageString
        }
    }

    private func decodeMiniMaxUsageData(from data: Data) throws -> UsageData {
        let decoder = JSONDecoder()
        let response = try decoder.decode(MiniMaxUsageAPIResponse.self, from: data)

        guard response.baseResp.statusCode == 0 else {
            throw UsageError.apiError(response.baseResp.statusMessage)
        }

        let models = response.modelRemains.map { model in
            ModelUsageData(
                provider: .miniMax,
                modelName: model.modelName,
                currentIntervalTotal: model.currentIntervalTotalCount,
                currentIntervalUsed: model.currentIntervalUsageCount,
                weeklyTotal: model.currentWeeklyTotalCount,
                weeklyUsed: model.currentWeeklyUsageCount,
                remainsTime: Int(model.remainsTime),
                startTime: date(fromMilliseconds: model.startTime),
                endTime: date(fromMilliseconds: model.endTime),
                weeklyStartTime: date(fromMilliseconds: model.weeklyStartTime),
                weeklyEndTime: date(fromMilliseconds: model.weeklyEndTime)
            )
        }
        let trackedModelCount = max(models.count, 1)
        let readyModelsCount = models.filter(\.isCurrentIntervalAvailable).count

        return UsageData(
            provider: .miniMax,
            remains: readyModelsCount,
            total: trackedModelCount,
            timestamp: Date(),
            models: models
        )
    }

    private func decodeGLMUsageData(from data: Data) throws -> UsageData {
        let decoder = JSONDecoder()
        let response = try decoder.decode(GLMQuotaLimitResponse.self, from: data)

        guard response.success == true, response.code == 200 else {
            throw UsageError.apiError(response.msg ?? AppLanguage.current.text(.unknownError))
        }

        let models = response.data?.limits.compactMap(glmModel(from:)) ?? []
        let trackedModelCount = max(models.count, 1)
        let readyModelsCount = models.filter(\.isCurrentIntervalAvailable).count

        return UsageData(
            provider: .glm,
            remains: readyModelsCount,
            total: trackedModelCount,
            timestamp: Date(),
            models: models
        )
    }

    private func glmModel(from limit: GLMUsageLimitItem) -> ModelUsageData? {
        guard limit.usage > 0 else { return nil }

        let total = Int(limit.usage.rounded())
        let used = Int(limit.currentValue.rounded())
        let remaining = max(0, total - used)
        let endTime = limit.nextResetTime.flatMap(date(fromMilliseconds:))
        let startTime = limit.type == "TOKENS_LIMIT"
            ? endTime?.addingTimeInterval(-5 * 60 * 60)
            : nil

        return ModelUsageData(
            provider: .glm,
            modelName: glmModelName(for: limit.type),
            currentIntervalTotal: total,
            currentIntervalUsed: remaining,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: endTime.map { max(0, Int($0.timeIntervalSince(Date()) * 1000)) } ?? 0,
            startTime: startTime,
            endTime: endTime,
            weeklyStartTime: nil,
            weeklyEndTime: nil
        )
    }

    private func glmModelName(for type: String) -> String {
        switch type {
        case "TOKENS_LIMIT":
            return "GLM Tokens (5h)"
        case "TIME_LIMIT":
            return "GLM MCP (month)"
        default:
            return "GLM \(type)"
        }
    }

    private func date(fromMilliseconds value: Int64) -> Date? {
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value) / 1000)
    }

    /// Fetch current usage data from the active provider API
    func fetchUsage(provider: UsageProvider) async throws -> UsageData {
        guard let credential = KeychainService.shared.getCredential(for: provider) else {
            throw UsageError.notConfigured
        }

        switch provider {
        case .miniMax:
            return try await fetchMiniMaxUsage(apiKey: credential)
        case .glm:
            return try await fetchGLMUsage(credentialInput: credential)
        }
    }

    private func fetchMiniMaxUsage(apiKey: String) async throws -> UsageData {
        guard let url = URL(string: miniMaxAPIURL) else {
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
            return try decodeMiniMaxUsageData(from: data)
        } catch let usageError as UsageError {
            throw usageError
        } catch {
            throw UsageError.invalidResponse
        }
    }

    private func fetchGLMUsage(credentialInput: String) async throws -> UsageData {
        let credential = try GLMCredential.parse(credentialInput)
        guard let url = URL(string: credential.apiURL) else {
            throw UsageError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyGLMHeaders(credential, to: &request)
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
            return try decodeGLMUsageData(from: data)
        } catch let usageError as UsageError {
            throw usageError
        } catch {
            throw UsageError.apiError("Unable to parse GLM response: \(responseSnippet(from: data))")
        }
    }

    private func applyGLMHeaders(_ credential: GLMCredential, to request: inout URLRequest) {
        for (name, value) in credential.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        if credential.headers["accept"] == nil {
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        }
        if credential.headers["content-type"] == nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if credential.headers["authorization"] == nil {
            request.setValue(credential.authorization, forHTTPHeaderField: "Authorization")
        }
        if credential.headers["accept-language"] == nil {
            request.setValue("zh", forHTTPHeaderField: "Accept-Language")
        }
        if credential.headers["set-language"] == nil {
            request.setValue("zh", forHTTPHeaderField: "Set-Language")
        }

        if let organization = credential.organization, !organization.isEmpty {
            request.setValue(organization, forHTTPHeaderField: "bigmodel-organization")
        }
        if let project = credential.project, !project.isEmpty {
            request.setValue(project, forHTTPHeaderField: "bigmodel-project")
        }
        if let cookie = credential.cookie, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
    }

    private func responseSnippet(from data: Data) -> String {
        guard let string = String(data: data, encoding: .utf8) else {
            return "non-UTF8 response (\(data.count) bytes)"
        }

        let compact = string
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard compact.count > 700 else { return compact }
        return "\(compact.prefix(700))..."
    }

    /// Test API connection with given provider credential
    func testConnection(credential: String, provider: UsageProvider) async throws -> Bool {
        switch provider {
        case .miniMax:
            return try await testMiniMaxConnection(apiKey: credential)
        case .glm:
            return try await testGLMConnection(credentialInput: credential)
        }
    }

    private func testMiniMaxConnection(apiKey: String) async throws -> Bool {
        guard let url = URL(string: miniMaxAPIURL) else {
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
            _ = try decodeMiniMaxUsageData(from: data)
            return true
        } catch {
            return false
        }
    }

    private func testGLMConnection(credentialInput: String) async throws -> Bool {
        _ = try await fetchGLMUsage(credentialInput: credentialInput)
        return true
    }
}
