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
        case .chatGPT:
            return try ChatGPTCredentialCollection.parseStorage(credential).storageString
        }
    }

    func prepareChatGPTCredentialsForStorage(_ credentials: [(id: String, name: String, credentialInput: String)]) throws -> String {
        try ChatGPTCredentialCollection.storageString(from: credentials)
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
                accountName: nil,
                modelName: model.modelName,
                currentIntervalTotal: model.currentIntervalTotalCount,
                currentIntervalUsed: model.currentIntervalUsageCount,
                weeklyTotal: model.currentWeeklyTotalCount,
                weeklyUsed: model.currentWeeklyUsageCount,
                remainsTime: Int(model.remainsTime),
                startTime: date(fromMilliseconds: model.startTime),
                endTime: date(fromMilliseconds: model.endTime),
                weeklyStartTime: date(fromMilliseconds: model.weeklyStartTime),
                weeklyEndTime: date(fromMilliseconds: model.weeklyEndTime),
                valueSuffix: nil,
                detailText: nil
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
        try decodeGLMUsageData(from: data, subscriptionResetTime: nil)
    }

    private func decodeGLMUsageData(from data: Data, subscriptionResetTime: Date?) throws -> UsageData {
        let decoder = JSONDecoder()
        let response = try decoder.decode(GLMQuotaLimitResponse.self, from: data)

        guard response.success == true, response.code == 200 else {
            throw UsageError.apiError(response.msg ?? AppLanguage.current.text(.unknownError))
        }

        let models = response.data?.limits.compactMap {
            glmModel(from: $0, subscriptionResetTime: subscriptionResetTime)
        } ?? []
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

    private func glmModel(from limit: GLMUsageLimitItem, subscriptionResetTime: Date?) -> ModelUsageData? {
        let normalized = normalizedGLMQuotaValues(for: limit)
        guard normalized.total > 0 else { return nil }

        let endTime = limit.nextResetTime.flatMap(date(fromMilliseconds:))
            ?? (limit.type == "TIME_LIMIT" ? subscriptionResetTime : nil)
        let startTime = limit.type == "TOKENS_LIMIT"
            ? endTime?.addingTimeInterval(-5 * 60 * 60)
            : nil

        return ModelUsageData(
            provider: .glm,
            accountName: nil,
            modelName: glmModelName(for: limit),
            currentIntervalTotal: normalized.total,
            currentIntervalUsed: normalized.remaining,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: endTime.map { max(0, Int($0.timeIntervalSince(Date()) * 1000)) } ?? 0,
            startTime: startTime,
            endTime: endTime,
            weeklyStartTime: nil,
            weeklyEndTime: nil,
            valueSuffix: normalized.valueSuffix,
            detailText: glmDetailText(for: limit, used: normalized.used, total: normalized.total)
        )
    }

    private func normalizedGLMQuotaValues(for limit: GLMUsageLimitItem) -> (used: Int, remaining: Int, total: Int, valueSuffix: String?) {
        if limit.usage > 0 {
            let total = Int(limit.usage.rounded())
            let used = Int(limit.currentValue.rounded())
            let remaining = Int((limit.remaining ?? max(0, limit.usage - limit.currentValue)).rounded())
            return (used: used, remaining: max(0, remaining), total: total, valueSuffix: nil)
        }

        if let percentage = limit.percentage {
            let used = min(max(Int(percentage.rounded()), 0), 100)
            return (used: used, remaining: max(0, 100 - used), total: 100, valueSuffix: "%")
        }

        return (used: 0, remaining: 0, total: 0, valueSuffix: nil)
    }

    private func glmModelName(for limit: GLMUsageLimitItem) -> String {
        switch limit.type {
        case "TOKENS_LIMIT":
            return "GLM Tokens (\(glmPeriodText(unit: limit.unit, number: limit.number, fallback: "5h")))"
        case "TIME_LIMIT":
            return "GLM MCP/Search (\(glmPeriodText(unit: limit.unit, number: limit.number, fallback: "month")))"
        default:
            return "GLM \(limit.type)"
        }
    }

    private func glmDetailText(for limit: GLMUsageLimitItem, used: Int, total: Int) -> String? {
        var details: [String] = []

        if let percentage = limit.percentage {
            details.append(String(format: "%.1f%% used", percentage))
        } else if total > 0 {
            details.append("\(used) used")
        }

        let usageDetails = limit.usageDetails
            .filter { $0.usage > 0 }
            .sorted { $0.usage > $1.usage }
            .prefix(3)
            .map { "\($0.modelCode): \(Int($0.usage.rounded()))" }

        if !usageDetails.isEmpty {
            details.append(usageDetails.joined(separator: " · "))
        }

        return details.isEmpty ? nil : details.joined(separator: " · ")
    }

    private func glmPeriodText(unit: Int?, number: Int?, fallback: String) -> String {
        guard let unit, let number else { return fallback }

        switch unit {
        case 1:
            return "\(number)m"
        case 2:
            return "\(number)h"
        case 3:
            return "\(number)h"
        case 4:
            return "\(number)d"
        case 5:
            return number == 1 ? "month" : "\(number)mo"
        default:
            return fallback
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
        case .chatGPT:
            return try await fetchChatGPTAccountsUsage(credentialInput: credential)
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
            let subscriptionResetTime = try? await fetchGLMSubscriptionResetTime(credential: credential)
            return try decodeGLMUsageData(from: data, subscriptionResetTime: subscriptionResetTime)
        } catch let usageError as UsageError {
            throw usageError
        } catch {
            throw UsageError.apiError("Unable to parse GLM response: \(responseSnippet(from: data))")
        }
    }

    private func fetchChatGPTUsage(credentialInput: String) async throws -> UsageData {
        let credential = try ChatGPTCredential.parse(credentialInput)
        return try await fetchChatGPTUsage(credential: credential, accountName: nil)
    }

    private func fetchChatGPTAccountsUsage(credentialInput: String) async throws -> UsageData {
        let collection = try ChatGPTCredentialCollection.parseStorage(credentialInput)
        var models: [ModelUsageData] = []
        var firstError: UsageError?
        let timestamp = Date()

        for account in collection.accounts {
            do {
                let data = try await fetchChatGPTUsage(credential: account.credential, accountName: account.name)
                models.append(contentsOf: data.models)
            } catch let usageError as UsageError {
                if firstError == nil {
                    firstError = usageError
                }
            } catch {
                if firstError == nil {
                    firstError = .networkError(error)
                }
            }
        }

        guard !models.isEmpty else {
            throw firstError ?? UsageError.notConfigured
        }

        return UsageData(
            provider: .chatGPT,
            remains: models.filter(\.isCurrentIntervalAvailable).count,
            total: models.count,
            timestamp: timestamp,
            models: models
        )
    }

    private func fetchChatGPTUsage(credential: ChatGPTCredential, accountName: String?) async throws -> UsageData {
        guard let url = URL(string: credential.apiURL) else {
            throw UsageError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyChatGPTHeaders(credential, to: &request)
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
            return try decodeChatGPTUsageData(from: data, accountName: accountName)
        } catch let usageError as UsageError {
            throw usageError
        } catch {
            throw UsageError.apiError("Unable to parse ChatGPT response: \(responseSnippet(from: data))")
        }
    }

    private func decodeChatGPTUsageData(from data: Data) throws -> UsageData {
        try decodeChatGPTUsageData(from: data, accountName: nil)
    }

    private func decodeChatGPTUsageData(from data: Data, accountName: String?) throws -> UsageData {
        let json = try JSONDecoder().decode(AnyJSONValue.self, from: data)
        let planType = chatGPTPlanType(in: json)
        let quotaModels = chatGPTQuotaCandidates(in: json)
        let models: [ModelUsageData]

        if quotaModels.isEmpty {
            let planName = planType.map { "ChatGPT \($0.capitalized)" } ?? "ChatGPT account"
            models = [
                ModelUsageData(
                    provider: .chatGPT,
                    accountName: accountName,
                    modelName: planName,
                    currentIntervalTotal: 1,
                    currentIntervalUsed: 1,
                    weeklyTotal: 0,
                    weeklyUsed: 0,
                    remainsTime: 0,
                    startTime: nil,
                    endTime: nil,
                    weeklyStartTime: nil,
                    weeklyEndTime: nil,
                    valueSuffix: nil,
                    detailText: "Plan \(planType ?? "unknown") · paste a ChatGPT quota endpoint curl to show remaining model limits"
                )
            ]
        } else {
            models = quotaModels.map { quota in
                ModelUsageData(
                    provider: .chatGPT,
                    accountName: accountName,
                    modelName: quota.name,
                    currentIntervalTotal: quota.total,
                    currentIntervalUsed: quota.remaining,
                    weeklyTotal: quota.weeklyTotal,
                    weeklyUsed: quota.weeklyRemaining,
                    remainsTime: quota.endTime.map { max(0, Int($0.timeIntervalSince(Date()) * 1000)) } ?? 0,
                    startTime: quota.startTime,
                    endTime: quota.endTime,
                    weeklyStartTime: quota.weeklyStartTime,
                    weeklyEndTime: quota.weeklyEndTime,
                    valueSuffix: quota.valueSuffix,
                    detailText: quota.detailText(planType: planType)
                )
            }
        }

        let trackedModelCount = max(models.count, 1)
        let readyModelsCount = models.filter(\.isCurrentIntervalAvailable).count

        return UsageData(
            provider: .chatGPT,
            remains: readyModelsCount,
            total: trackedModelCount,
            timestamp: Date(),
            models: models
        )
    }

    private func applyChatGPTHeaders(_ credential: ChatGPTCredential, to request: inout URLRequest) {
        for (name, value) in credential.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        if credential.headers["accept"] == nil {
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        }
        if credential.headers["content-type"] == nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if credential.headers["user-agent"] == nil {
            request.setValue("AIQuotaBar/1.0", forHTTPHeaderField: "User-Agent")
        }
        if credential.headers["authorization"] == nil,
           let authorization = credential.authorization,
           !authorization.isEmpty {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        if let cookie = credential.cookie, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
    }

    private func chatGPTPlanType(in json: AnyJSONValue) -> String? {
        if case .object(let object) = json {
            for key in ["planType", "plan_type", "plan", "account_plan", "subscription_plan"] {
                if let value = object[key]?.stringValue, !value.isEmpty {
                    return value
                }
            }
        }

        for child in json.children {
            if let planType = chatGPTPlanType(in: child) {
                return planType
            }
        }

        return nil
    }

    private func chatGPTQuotaCandidates(in json: AnyJSONValue) -> [ChatGPTQuotaCandidate] {
        var candidates: [ChatGPTQuotaCandidate] = []
        collectChatGPTQuotaCandidates(from: json, inheritedName: nil, into: &candidates)

        let namedCandidates = candidates.filter { $0.name != "ChatGPT quota" }
        let preferredCandidates = namedCandidates.isEmpty ? candidates : namedCandidates
        var bestByWindow: [String: ChatGPTQuotaCandidate] = [:]

        for candidate in preferredCandidates {
            let key = chatGPTWindowKey(for: candidate)
            if let existing = bestByWindow[key] {
                bestByWindow[key] = moreSpecificChatGPTCandidate(existing, candidate)
            } else {
                bestByWindow[key] = candidate
            }
        }

        return bestByWindow.values.sorted { lhs, rhs in
            chatGPTWindowSortWeight(lhs) < chatGPTWindowSortWeight(rhs)
        }
    }

    private func collectChatGPTQuotaCandidates(
        from json: AnyJSONValue,
        inheritedName: String?,
        into candidates: inout [ChatGPTQuotaCandidate]
    ) {
        switch json {
        case .object(let object):
            if let candidate = chatGPTQuotaCandidate(from: object, inheritedName: inheritedName) {
                candidates.append(candidate)
            }

            for (key, value) in object {
                let childName = chatGPTInheritedWindowName(for: key) ?? inheritedName
                collectChatGPTQuotaCandidates(from: value, inheritedName: childName, into: &candidates)
            }
        case .array(let values):
            for value in values {
                collectChatGPTQuotaCandidates(from: value, inheritedName: inheritedName, into: &candidates)
            }
        default:
            break
        }
    }

    private func chatGPTQuotaCandidate(
        from object: [String: AnyJSONValue],
        inheritedName: String?
    ) -> ChatGPTQuotaCandidate? {
        let explicitTotal = firstInt(in: object, matching: chatGPTTotalKeys)
        let percentRemaining = firstPercentage(in: object, matching: chatGPTPercentageRemainingKeys)
        let percentUsed = firstPercentage(in: object, matching: chatGPTPercentageUsedKeys)
        let total = explicitTotal ?? (percentRemaining == nil && percentUsed == nil ? nil : 100)

        guard let total, total > 0 else { return nil }

        let remaining = firstInt(in: object, matching: chatGPTRemainingKeys)
        let used = firstInt(in: object, matching: chatGPTUsedKeys)
        let currentRemaining: Int
        let valueSuffix: String?

        if let percentRemaining {
            currentRemaining = percentRemaining
            valueSuffix = "%"
        } else if let percentUsed {
            currentRemaining = max(0, 100 - percentUsed)
            valueSuffix = "%"
        } else if let remaining {
            currentRemaining = remaining
            valueSuffix = nil
        } else if let used {
            currentRemaining = max(0, total - used)
            valueSuffix = nil
        } else {
            return nil
        }

        let name = chatGPTModelName(from: object, inheritedName: inheritedName)
        let endTime = firstDate(in: object, matching: chatGPTResetKeys)
            ?? firstResetIntervalDate(in: object)
        let startTime = chatGPTWindowStartTime(name: name, endTime: endTime)

        return ChatGPTQuotaCandidate(
            name: name,
            total: total,
            remaining: max(0, min(currentRemaining, total)),
            valueSuffix: valueSuffix,
            weeklyTotal: 0,
            weeklyRemaining: 0,
            startTime: startTime,
            endTime: endTime,
            weeklyStartTime: nil,
            weeklyEndTime: nil
        )
    }

    private func chatGPTWindowStartTime(name: String, endTime: Date?) -> Date? {
        guard let endTime else { return nil }

        let loweredName = name.lowercased()
        if loweredName.contains("5h") || loweredName.contains("primary") || loweredName.contains("session") {
            return endTime.addingTimeInterval(-5 * 60 * 60)
        }

        if loweredName.contains("weekly") || loweredName.contains("7d") || loweredName.contains("secondary") {
            return endTime.addingTimeInterval(-7 * 24 * 60 * 60)
        }

        let remaining = endTime.timeIntervalSince(Date())
        if remaining > 0, remaining < 86_400 {
            return endTime.addingTimeInterval(-5 * 60 * 60)
        }

        return nil
    }

    private func chatGPTWindowKey(for candidate: ChatGPTQuotaCandidate) -> String {
        let loweredName = candidate.name.lowercased()
        if loweredName.contains("5h") || loweredName.contains("primary") || loweredName.contains("session") {
            return "primary"
        }
        if loweredName.contains("weekly") || loweredName.contains("7d") || loweredName.contains("secondary") {
            return "secondary"
        }

        if let endTime = candidate.endTime {
            let seconds = endTime.timeIntervalSince(Date())
            if seconds > 86_400 {
                return "secondary"
            }
            return "primary"
        }

        return candidate.name.lowercased()
    }

    private func moreSpecificChatGPTCandidate(
        _ lhs: ChatGPTQuotaCandidate,
        _ rhs: ChatGPTQuotaCandidate
    ) -> ChatGPTQuotaCandidate {
        if lhs.name == "ChatGPT quota", rhs.name != "ChatGPT quota" {
            return rhs
        }
        if rhs.name == "ChatGPT quota", lhs.name != "ChatGPT quota" {
            return lhs
        }
        if lhs.endTime == nil, rhs.endTime != nil {
            return rhs
        }
        return lhs
    }

    private func chatGPTWindowSortWeight(_ candidate: ChatGPTQuotaCandidate) -> Int {
        switch chatGPTWindowKey(for: candidate) {
        case "primary":
            return 0
        case "secondary":
            return 1
        default:
            return 2
        }
    }

    private var chatGPTTotalKeys: [String] {
        ["total", "limit", "cap", "max", "quota", "message_cap", "messageCap", "message_limit", "messageLimit"]
    }

    private var chatGPTRemainingKeys: [String] {
        ["remaining", "remain", "available", "messages_remaining", "messagesRemaining", "remaining_messages", "remainingMessages"]
    }

    private var chatGPTPercentageRemainingKeys: [String] {
        [
            "remaining_percent",
            "remainingPercent",
            "remaining_percentage",
            "remainingPercentage",
            "percent_remaining",
            "percentRemaining",
            "percentage_remaining",
            "percentageRemaining",
            "available_percent",
            "availablePercent",
            "available_percentage",
            "availablePercentage",
            "rate_limit_remaining",
            "rateLimitRemaining",
            "rate_limits_remaining",
            "rateLimitsRemaining",
            "remaining_quota_percent",
            "remainingQuotaPercent",
            "quota_remaining_percent",
            "quotaRemainingPercent",
            "remaining_pct",
            "remainingPct"
        ]
    }

    private var chatGPTPercentageUsedKeys: [String] {
        [
            "utilization",
            "utilisation",
            "utilization_percent",
            "utilizationPercent",
            "used_percent",
            "usedPercent",
            "used_percentage",
            "usedPercentage",
            "percent_used",
            "percentUsed",
            "usage_percent",
            "usagePercent",
            "usage_percentage",
            "usagePercentage",
            "used_pct",
            "usedPct"
        ]
    }

    private var chatGPTUsedKeys: [String] {
        ["used", "usage", "current", "count", "messages_used", "messagesUsed", "used_messages", "usedMessages"]
    }

    private var chatGPTResetKeys: [String] {
        ["reset", "reset_at", "resetAt", "resets_at", "resetsAt", "reset_time", "resetTime", "next_reset", "nextReset", "nextResetTime", "reset_date", "resetDate"]
    }

    private var chatGPTResetIntervalKeys: [String] {
        [
            "reset_after_seconds",
            "resetAfterSeconds",
            "seconds_until_reset",
            "secondsUntilReset",
            "reset_in_seconds",
            "resetInSeconds",
            "resets_in_seconds",
            "resetsInSeconds",
            "reset_after",
            "resetAfter",
            "resets_in",
            "resetsIn"
        ]
    }

    private func firstInt(in object: [String: AnyJSONValue], matching keys: [String]) -> Int? {
        for key in keys {
            if let value = object[key], let int = intValue(from: value) {
                return int
            }
        }

        let lowercasedKeys = Dictionary(uniqueKeysWithValues: object.map { ($0.key.lowercased(), $0.value) })
        for key in keys {
            if let value = lowercasedKeys[key.lowercased()], let int = intValue(from: value) {
                return int
            }
        }

        return nil
    }

    private func firstPercentage(in object: [String: AnyJSONValue], matching keys: [String]) -> Int? {
        for key in keys {
            if let value = object[key], let percentage = percentageValue(from: value) {
                return percentage
            }
        }

        let lowercasedKeys = Dictionary(uniqueKeysWithValues: object.map { ($0.key.lowercased(), $0.value) })
        for key in keys {
            if let value = lowercasedKeys[key.lowercased()], let percentage = percentageValue(from: value) {
                return percentage
            }
        }

        return nil
    }

    private func firstDate(in object: [String: AnyJSONValue], matching keys: [String]) -> Date? {
        for key in keys {
            if let value = object[key], let date = chatGPTDate(from: value) {
                return date
            }
        }

        let lowercasedKeys = Dictionary(uniqueKeysWithValues: object.map { ($0.key.lowercased(), $0.value) })
        for key in keys {
            if let value = lowercasedKeys[key.lowercased()], let date = chatGPTDate(from: value) {
                return date
            }
        }

        return nil
    }

    private func firstResetIntervalDate(in object: [String: AnyJSONValue]) -> Date? {
        for key in chatGPTResetIntervalKeys {
            if let value = object[key], let interval = secondsValue(from: value) {
                return Date().addingTimeInterval(interval)
            }
        }

        let lowercasedKeys = Dictionary(uniqueKeysWithValues: object.map { ($0.key.lowercased(), $0.value) })
        for key in chatGPTResetIntervalKeys {
            if let value = lowercasedKeys[key.lowercased()], let interval = secondsValue(from: value) {
                return Date().addingTimeInterval(interval)
            }
        }

        return nil
    }

    private func intValue(from value: AnyJSONValue) -> Int? {
        if let number = value.doubleValue {
            return Int(number.rounded())
        }
        if let string = value.stringValue {
            guard let number = Double(string) else { return nil }
            let int = Int(number.rounded())
            return int >= 0 ? int : nil
        }
        return nil
    }

    private func percentageValue(from value: AnyJSONValue) -> Int? {
        if let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) {
            let normalized = string.replacingOccurrences(of: "%", with: "")
            guard let number = Double(normalized) else { return nil }
            let percentage = number <= 1 ? number * 100 : number
            return min(max(Int(percentage.rounded()), 0), 100)
        }

        guard let number = value.doubleValue else { return nil }
        let percentage = number <= 1 ? number * 100 : number
        return min(max(Int(percentage.rounded()), 0), 100)
    }

    private func secondsValue(from value: AnyJSONValue) -> TimeInterval? {
        guard let number = value.doubleValue else { return nil }
        let seconds = number > 10_000_000 ? number / 1000 : number
        return seconds > 0 ? seconds : nil
    }

    private func chatGPTDate(from value: AnyJSONValue) -> Date? {
        if let number = value.doubleValue {
            let raw = number > 10_000_000_000 ? number / 1000 : number
            return Date(timeIntervalSince1970: raw)
        }

        guard let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else {
            return nil
        }

        if let number = Double(string) {
            let raw = number > 10_000_000_000 ? number / 1000 : number
            return Date(timeIntervalSince1970: raw)
        }

        let isoFormatter = ISO8601DateFormatter()
        if let date = isoFormatter.date(from: string) {
            return date
        }

        return nil
    }

    private func chatGPTModelName(from object: [String: AnyJSONValue], inheritedName: String?) -> String {
        for key in ["window", "period", "duration", "bucket", "type", "model", "model_slug", "modelSlug", "model_name", "modelName", "name", "title", "id"] {
            if let value = object[key]?.stringValue, quotaLikeKey(value) {
                return chatGPTDisplayName(for: value)
            }
        }

        if let inheritedName, quotaLikeKey(inheritedName) {
            return chatGPTDisplayName(for: inheritedName)
        }

        return "ChatGPT quota"
    }

    private func chatGPTInheritedWindowName(for key: String) -> String? {
        let lowered = key.lowercased()
        if lowered.contains("primary_window") ||
            lowered == "primary" ||
            lowered.contains("session") ||
            lowered.contains("5h") ||
            lowered.contains("5_hour") ||
            lowered.contains("five_hour") ||
            lowered.contains("short") {
            return "5h"
        }

        if lowered.contains("secondary_window") ||
            lowered == "secondary" ||
            lowered.contains("weekly") ||
            lowered.contains("7d") ||
            lowered.contains("7_day") ||
            lowered.contains("week") ||
            lowered.contains("long") {
            return "Weekly"
        }

        return quotaLikeKey(key) ? key : nil
    }

    private func quotaLikeKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return lowered.contains("gpt") ||
            lowered.contains("o3") ||
            lowered.contains("o4") ||
            lowered.contains("model") ||
            lowered.contains("thinking") ||
            lowered.contains("pro") ||
            lowered.contains("5h") ||
            lowered.contains("5_hour") ||
            lowered.contains("five_hour") ||
            lowered.contains("short") ||
            lowered.contains("weekly") ||
            lowered.contains("week") ||
            lowered.contains("long")
    }

    private func chatGPTDisplayName(for value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = normalized.lowercased()

        if lowered.contains("primary window") ||
            lowered == "primary" ||
            lowered.contains("5h") ||
            lowered.contains("5 hour") ||
            lowered.contains("session") ||
            lowered.contains("short") {
            return "5h"
        }
        if lowered.contains("secondary window") ||
            lowered == "secondary" ||
            lowered.contains("weekly") ||
            lowered.contains("7d") ||
            lowered.contains("7 day") ||
            lowered.contains("week") ||
            lowered.contains("long") {
            return "Weekly"
        }
        return normalized.isEmpty ? "ChatGPT quota" : normalized
    }

    private func fetchGLMSubscriptionResetTime(credential: GLMCredential) async throws -> Date? {
        guard let url = subscriptionURL(from: credential.apiURL) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyGLMHeaders(credential, to: &request)
        request.timeoutInterval = 15

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return nil
        }

        let decoded = try JSONDecoder().decode(GLMSubscriptionListResponse.self, from: data)
        guard decoded.success, decoded.code == 200 else { return nil }

        return decoded.data?
            .compactMap(subscriptionResetDate)
            .min { lhs, rhs in
                let now = Date()
                let lhsInterval = lhs.timeIntervalSince(now)
                let rhsInterval = rhs.timeIntervalSince(now)
                if lhsInterval >= 0, rhsInterval >= 0 {
                    return lhsInterval < rhsInterval
                }
                return lhs > rhs
            }
    }

    private func subscriptionURL(from quotaURL: String) -> URL? {
        guard let url = URL(string: quotaURL),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        components.path = "/api/biz/subscription/list"
        components.query = nil
        return components.url
    }

    private func subscriptionResetDate(from item: GLMSubscriptionItem) -> Date? {
        if let nextRenewTime = item.nextRenewTime,
           let date = parseGLMDate(nextRenewTime) {
            return date
        }

        guard let valid = item.valid else { return nil }
        let parts = valid.components(separatedBy: "-")
        guard parts.count >= 6 else { return nil }
        let endString = parts.suffix(3).joined(separator: "-")
        return parseGLMDate(endString)
    }

    private func parseGLMDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")

        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        if let milliseconds = Int64(trimmed) {
            return date(fromMilliseconds: milliseconds)
        }

        return nil
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
        case .chatGPT:
            return try await testChatGPTConnection(credentialInput: credential)
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

    private func testChatGPTConnection(credentialInput: String) async throws -> Bool {
        _ = try await fetchChatGPTUsage(credentialInput: credentialInput)
        return true
    }
}

private struct ChatGPTQuotaCandidate {
    let name: String
    let total: Int
    let remaining: Int
    let valueSuffix: String?
    let weeklyTotal: Int
    let weeklyRemaining: Int
    let startTime: Date?
    let endTime: Date?
    let weeklyStartTime: Date?
    let weeklyEndTime: Date?

    func detailText(planType: String?) -> String? {
        var details: [String] = []
        if let planType, !planType.isEmpty {
            details.append("Plan \(planType)")
        }
        if let endTime {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = "MM/dd HH:mm"
            details.append("resets \(formatter.string(from: endTime))")
        }
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }
}

private enum AnyJSONValue: Decodable {
    case object([String: AnyJSONValue])
    case array([AnyJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            var object: [String: AnyJSONValue] = [:]
            for key in container.allKeys {
                object[key.stringValue] = try container.decode(AnyJSONValue.self, forKey: key)
            }
            self = .object(object)
            return
        }

        if var container = try? decoder.unkeyedContainer() {
            var array: [AnyJSONValue] = []
            while !container.isAtEnd {
                array.append(try container.decode(AnyJSONValue.self))
            }
            self = .array(array)
            return
        }

        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            self = .null
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return String(value)
        case .bool(let value):
            return String(value)
        default:
            return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value):
            return value
        case .string(let value):
            return Double(value)
        default:
            return nil
        }
    }

    var children: [AnyJSONValue] {
        switch self {
        case .object(let object):
            return Array(object.values)
        case .array(let values):
            return values
        default:
            return []
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
