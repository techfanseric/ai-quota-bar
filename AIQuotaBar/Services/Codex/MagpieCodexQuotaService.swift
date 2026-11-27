import CodexBarCore
import Foundation

protocol MagpieCodexQuotaProviding: Sendable {
    func fetchUsage() async throws -> UsageData?
}

/// Reads Codex allowance cards from the local Magpie gateway.
///
/// Magpie owns the multi-account sign-ins and their refresh-token lifecycle, so
/// AIQuotaBar reads its quota report instead of refreshing each saved Codex
/// account itself. Discovery is deliberately limited to the loopback gateway
/// already named by Codex's config.toml; no API key or vendor credential is
/// handled here.
actor MagpieCodexQuotaService: MagpieCodexQuotaProviding {
    private let configURL: URL
    private let session: URLSession
    private let redirectGuard = NoRedirects()

    init(configURL: URL? = nil, session: URLSession? = nil) {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        self.configURL = configURL ?? home.appendingPathComponent("config.toml")
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [
                "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
            ]
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            // The report can wait for Magpie's first uncached account read;
            // its gateway bounds that work at 12 seconds.
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            self.session = URLSession(configuration: configuration)
        }
    }

    func fetchUsage() async throws -> UsageData? {
        try await fetchUsage(cachedOnly: false)
    }

    func fetchCachedUsage() async throws -> UsageData? {
        try await fetchUsage(cachedOnly: true)
    }

    private func fetchUsage(cachedOnly: Bool) async throws -> UsageData? {
        guard let configData = try? Data(contentsOf: configURL),
              configData.count <= 1 << 20,
              let config = String(data: configData, encoding: .utf8),
              let endpoint = MagpieModelActivityDetector.endpoint(in: config)
        else { return nil }

        let root = endpoint.url
        var url = root.appendingPathComponent("v1/magpie/quotas")
        if cachedOnly {
            url.append(queryItems: [URLQueryItem(name: "kept", value: "1")])
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        let (bytes, response) = try await session.bytes(for: request, delegate: redirectGuard)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200,
              response.expectedContentLength <= 4 << 20 else {
            throw ReadError.invalidResponse
        }

        var data = Data()
        for try await byte in bytes {
            guard data.count < 4 << 20 else { throw ReadError.invalidResponse }
            data.append(byte)
        }
        return try Self.usageData(from: data)
    }

    static func usageData(from data: Data) throws -> UsageData {
        let cards = try Self.decodeCards(from: data).filter {
            $0.provider == "codex"
                && ($0.from ?? "").isEmpty
                && ($0.kind == nil || $0.kind == "subscription")
        }
        guard !cards.isEmpty else { throw ReadError.noCodexCards }
        guard let currentCard = Self.currentCard(from: cards) else {
            throw ReadError.noCurrentAccount
        }

        let timestamp = Date()
        var models: [ModelUsageData] = []
        var effectiveRows: [ModelUsageData] = []
        var accountCount = 0
        var currentDisplayName = ""
        var currentSummary: ModelUsageData?

        for card in cards {
            accountCount += 1
            let accountName = (card.alias ?? card.user ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = accountName.isEmpty ? "Codex account \(card.index + 1)" : accountName
            if card.index == currentCard.index {
                currentDisplayName = displayName
            }
            let sampledAt = parseDate(card.readAt) ?? timestamp
            let finiteWindows = card.windows.filter { window in
                !(window.unlimited ?? false)
                    && !(window.text ?? false)
                    && window.remaining.isFinite
            }

            guard (card.error ?? "").isEmpty, !finiteWindows.isEmpty else {
                models.append(makeUnavailableModel(
                    accountName: displayName,
                    accountKey: card.user?.trimmingCharacters(
                        in: .whitespacesAndNewlines).lowercased(),
                    plan: card.plan,
                    sampledAt: sampledAt))
                continue
            }

            var limitingModel: ModelUsageData?
            for window in finiteWindows {
                let model = makeModel(
                    accountName: displayName,
                    accountKey: card.user?.trimmingCharacters(
                        in: .whitespacesAndNewlines).lowercased(),
                    plan: card.plan,
                    window: window,
                    sampledAt: sampledAt)
                models.append(model)
                if limitingModel == nil ||
                    model.currentIntervalPercentageRemaining <
                    limitingModel!.currentIntervalPercentageRemaining {
                    limitingModel = model
                }
            }
            if let limitingModel {
                effectiveRows.append(limitingModel)
                if card.index == currentCard.index {
                    currentSummary = limitingModel
                }
            }
        }

        guard !effectiveRows.isEmpty else { throw ReadError.noReadableCards }

        // Magpie commonly reports each account as a percentage. Without a
        // common absolute capacity across Pro and ProLite, averaging the most
        // limiting window per account is the least misleading pool signal.
        let totalRemaining = effectiveRows.reduce(0.0) {
            $0 + $1.currentIntervalPercentageRemaining
        }
        // A card Magpie could not read contributes no known capacity. Count it
        // as unavailable in the denominator so a partial outage cannot make the
        // pool look healthier than the accounts it can see.
        let poolRemaining = totalRemaining / Double(max(accountCount, 1))

        let poolPercent = Int(poolRemaining.rounded())
        let pool = ModelUsageData(
            provider: .codex,
            accountName: nil,
            modelName: "Codex Pool",
            currentIntervalTotal: max(accountCount, 1) * 100,
            currentIntervalUsed: Int(totalRemainingPoints(for: effectiveRows, accountCount: accountCount)),
            weeklyTotal: max(accountCount, 1) * 100,
            weeklyUsed: Int(totalRemainingPoints(for: effectiveRows, accountCount: accountCount)),
            remainsTime: 0,
            startTime: nil,
            endTime: effectiveRows.compactMap(\.endTime).min(),
            weeklyStartTime: nil,
            weeklyEndTime: effectiveRows.compactMap(\.endTime).min(),
            valueSuffix: "%",
            detailText: "Magpie · \(effectiveRows.count)/\(accountCount) accounts",
            currentIntervalRemainingPercent: poolPercent,
            weeklyRemainingPercent: poolPercent,
            progressBarPercentOverride: nil,
            progressBarRightText: nil,
            sampledAt: effectiveRows.compactMap(\.sampledAt).max())
        models.insert(pool, at: 0)
        models.insert(
            Self.makeCurrentSummary(
                accountName: currentDisplayName,
                source: currentSummary,
                sampledAt: parseDate(currentCard.readAt) ?? timestamp),
            at: 1)

        return UsageData(
            provider: .codex,
            remains: models.filter(\.isCurrentIntervalAvailable).count,
            total: models.count,
            timestamp: timestamp,
            models: models,
            subscribeTitle: nil,
            subscribeEndTime: nil)
    }

    private static func totalRemainingPoints(for rows: [ModelUsageData], accountCount: Int) -> Double {
        let known = rows.reduce(0.0) { $0 + $1.currentIntervalPercentageRemaining }
        return min(Double(max(accountCount, 1) * 100), known)
    }

    private static func currentCard(from cards: [Quota]) -> Quota? {
        if let marked = cards.first(where: { $0.last == true }) {
            return marked
        }
        let dated = cards.compactMap { card -> (Quota, Date)? in
            guard let raw = card.lastServedAt, let date = parseDate(raw) else { return nil }
            return (card, date)
        }
        if let latest = dated.max(by: { lhs, rhs in lhs.1 < rhs.1 })?.0 {
            return latest
        }
        // Fallback: when no explicit marker is present, treat the first card
        // as current so pool-only payloads still produce a ring.
        return cards.first
    }

    private static func makeCurrentSummary(
        accountName: String,
        source: ModelUsageData?,
        sampledAt: Date
    ) -> ModelUsageData {
        guard let source else {
            return ModelUsageData(
                provider: .codex,
                accountName: nil,
                modelName: "Codex Current",
                currentIntervalTotal: 1,
                currentIntervalUsed: 0,
                weeklyTotal: 0,
                weeklyUsed: 0,
                remainsTime: 0,
                startTime: nil,
                endTime: nil,
                weeklyStartTime: nil,
                weeklyEndTime: nil,
                valueSuffix: "%",
                detailText: "Magpie · Current account · \(accountName) unavailable",
                currentIntervalRemainingPercent: 0,
                weeklyRemainingPercent: 0,
                progressBarPercentOverride: nil,
                progressBarRightText: nil,
                sampledAt: sampledAt)
        }
        let remaining = Int(source.currentIntervalPercentageRemaining.rounded())
        return ModelUsageData(
            provider: .codex,
            accountName: nil,
            modelName: "Codex Current",
            currentIntervalTotal: 100,
            currentIntervalUsed: remaining,
            weeklyTotal: 100,
            weeklyUsed: remaining,
            remainsTime: source.remainsTime,
            startTime: source.startTime,
            endTime: source.endTime,
            weeklyStartTime: nil,
            weeklyEndTime: source.endTime,
            valueSuffix: "%",
            detailText: "Magpie · Current account",
            currentIntervalRemainingPercent: remaining,
            weeklyRemainingPercent: remaining,
            progressBarPercentOverride: nil,
            progressBarRightText: nil,
            sampledAt: sampledAt)
    }

    private static func makeModel(
        accountName: String,
        accountKey: String?,
        plan: String?,
        window: Quota.Window,
        sampledAt: Date
    ) -> ModelUsageData {
        let remaining = max(0, min(100, window.remaining))
        let resetsAt = parseDate(window.resetsAt)
        let name = displayName(for: window.name)
        let duration = windowDuration(for: name)
        let startTime = resetsAt.map { $0.addingTimeInterval(-duration) }
        return ModelUsageData(
            provider: .codex,
            accountName: accountName,
            modelName: name,
            currentIntervalTotal: 100,
            currentIntervalUsed: Int(remaining.rounded()),
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: resetsAt.map { Int($0.timeIntervalSinceNow * 1000) } ?? 0,
            startTime: startTime,
            endTime: resetsAt,
            weeklyStartTime: nil,
            weeklyEndTime: nil,
            valueSuffix: "%",
            detailText: makeDetail(plan: plan, resetsAt: resetsAt),
            currentIntervalRemainingPercent: Int(remaining.rounded()),
            weeklyRemainingPercent: nil,
            progressBarPercentOverride: nil,
            progressBarRightText: absoluteText(window),
            sampledAt: sampledAt,
            accountKey: accountKey)
    }

    private static func makeUnavailableModel(
        accountName: String,
        accountKey: String?,
        plan: String?,
        sampledAt: Date
    ) -> ModelUsageData {
        ModelUsageData(
            provider: .codex,
            accountName: accountName,
            modelName: "Magpie",
            currentIntervalTotal: 1,
            currentIntervalUsed: 0,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: 0,
            startTime: nil,
            endTime: nil,
            weeklyStartTime: nil,
            weeklyEndTime: nil,
            valueSuffix: nil,
            detailText: makeDetail(plan: plan, resetsAt: nil) ?? "Magpie",
            currentIntervalRemainingPercent: 0,
            weeklyRemainingPercent: nil,
            progressBarPercentOverride: nil,
            progressBarRightText: nil,
            sampledAt: sampledAt,
            accountKey: accountKey)
    }

    private static func makeDetail(plan: String?, resetsAt: Date?) -> String? {
        var parts = ["Magpie"]
        if let display = CodexPlanFormatting.displayName(plan) {
            parts.insert(display, at: 0)
        }
        if let resetsAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = "MM/dd HH:mm"
            parts.append("resets \(formatter.string(from: resetsAt))")
        }
        return parts.joined(separator: " · ")
    }

    private static func displayName(for raw: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name == "7 days" || name == "7 day" || name == "7d" { return "Weekly" }
        if name == "5 hours" || name == "5 hour" || name == "5h" { return "5h" }
        return raw.isEmpty ? "Quota" : raw
    }

    private static func windowDuration(for name: String) -> TimeInterval {
        if name == "Weekly" { return 7 * 24 * 3600 }
        if name == "5h" { return 5 * 3600 }
        return 0
    }

    private static func absoluteText(_ window: Quota.Window) -> String? {
        guard let amount = window.amount,
              let limit = window.limit,
              amount > 0, limit > 0, amount <= limit else {
            return nil
        }
        return "\(UsageFormatter.tokenCountString(Int(amount.rounded())))/\(UsageFormatter.tokenCountString(Int(limit.rounded())))"
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private struct Quota: Decodable {
        struct Window: Decodable {
            let name: String
            let unlimited: Bool?
            let text: Bool?
            let used: Double?
            let remaining: Double
            let resetsAt: String?
            let amount: Double?
            let limit: Double?
        }

        let provider: String
        let kind: String?
        let plan: String?
        let user: String?
        let alias: String?
        let windows: [Window]
        let error: String?
        let readAt: String?
        let from: String?
        let last: Bool?
        let lastServedAt: String?
        var index: Int = 0

        enum CodingKeys: String, CodingKey {
            case provider, kind, plan, user, alias, windows, error
            case readAt, from, last
            case lastServedAt = "lastServedAt"
        }

    }

    private static func decodeCards(from data: Data) throws -> [Quota] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let object = object as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else {
            throw ReadError.invalidResponse
        }
        let decoder = JSONDecoder()
        return try rows.enumerated().map { index, row in
            let cardData = try JSONSerialization.data(withJSONObject: row)
            var card = try decoder.decode(Quota.self, from: cardData)
            card.index = index
            return card
        }
    }

    private enum ReadError: Error {
        case invalidResponse
        case noCodexCards
        case noReadableCards
        case noCurrentAccount
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
