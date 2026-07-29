import Foundation

struct ClashAPIClient: Sendable {
    private let configuration: ClashControllerConfiguration
    private let session: URLSession
    private let webSocketSession: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        configuration: ClashControllerConfiguration,
        session: URLSession? = nil
    ) {
        self.configuration = configuration
        if let session {
            self.session = session
            webSocketSession = session
        } else {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest = 8
            sessionConfiguration.timeoutIntervalForResource = 10
            sessionConfiguration.waitsForConnectivity = false
            sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            sessionConfiguration.connectionProxyDictionary = [:]
            self.session = URLSession(configuration: sessionConfiguration)

            let webSocketConfiguration = URLSessionConfiguration.ephemeral
            webSocketConfiguration.timeoutIntervalForRequest = 8
            webSocketConfiguration.timeoutIntervalForResource = 24 * 60 * 60
            webSocketConfiguration.waitsForConnectivity = false
            webSocketConfiguration.requestCachePolicy =
                .reloadIgnoringLocalAndRemoteCacheData
            webSocketConfiguration.connectionProxyDictionary = [:]
            webSocketSession = URLSession(
                configuration: webSocketConfiguration)
        }
    }

    func version() async throws -> ClashVersionResponse {
        try await get(pathComponents: ["version"], as: ClashVersionResponse.self)
    }

    func loadConnectionsSnapshot() async throws -> ClashConnectionsResponse {
        try await get(
            pathComponents: ["connections"],
            as: ClashConnectionsResponse.self)
    }

    func connectionSnapshots(
        intervalMilliseconds: Int
    ) -> AsyncThrowingStream<ClashConnectionsResponse, Error> {
        AsyncThrowingStream { continuation in
            do {
                let request = try makeWebSocketRequest(
                    pathComponents: ["connections"],
                    queryItems: [
                        URLQueryItem(
                            name: "interval",
                            value: String(max(250, intervalMilliseconds))),
                    ])
                let webSocketTask = webSocketSession.webSocketTask(
                    with: request)

                let receiveTask = Task {
                    do {
                        while !Task.isCancelled {
                            let message = try await webSocketTask.receive()
                            let data: Data
                            switch message {
                            case let .data(messageData):
                                data = messageData
                            case let .string(messageString):
                                guard let messageData = messageString.data(
                                    using: .utf8) else {
                                    throw ClashIntegrationError.incompatibleResponse
                                }
                                data = messageData
                            @unknown default:
                                throw ClashIntegrationError.incompatibleResponse
                            }

                            do {
                                let snapshot = try JSONDecoder().decode(
                                    ClashConnectionsResponse.self,
                                    from: data)
                                continuation.yield(snapshot)
                            } catch {
                                throw ClashIntegrationError.incompatibleResponse
                            }
                        }
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }

                continuation.onTermination = { @Sendable _ in
                    receiveTask.cancel()
                    webSocketTask.cancel(
                        with: .goingAway,
                        reason: nil)
                }
                webSocketTask.resume()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func loadRouteSnapshot() async throws -> ClashRouteSnapshot {
        async let proxiesResponse = get(
            pathComponents: ["proxies"],
            as: ClashProxiesResponse.self)
        async let rulesResponse = get(
            pathComponents: ["rules"],
            as: ClashRulesResponse.self)

        let (proxies, rules) = try await (proxiesResponse, rulesResponse)
        guard let groupName = ClashOpenAIRouteResolver.resolveGroupName(
            rules: rules.rules,
            proxies: proxies.proxies),
            let group = proxies.proxies[groupName],
            let candidateNames = group.all,
            !candidateNames.isEmpty else {
            throw ClashIntegrationError.strategyGroupNotFound
        }

        let routes = candidateNames.map { name in
            let proxy = proxies.proxies[name]
            return ClashRoute(
                name: name,
                type: proxy?.type ?? "Unknown",
                delay: proxy?.history?.last?.delay,
                isSelected: name == group.now)
        }

        return ClashRouteSnapshot(
            groupName: groupName,
            selectedRouteName: group.now,
            routes: ClashRouteSorter.sorted(routes))
    }

    func testGroup(
        _ groupName: String,
        targetURL: URL = URL(string: "https://chatgpt.com/")!,
        timeoutMilliseconds: Int = 5_000
    ) async throws -> [String: Int] {
        try await get(
            pathComponents: ["group", groupName, "delay"],
            queryItems: [
                URLQueryItem(name: "url", value: targetURL.absoluteString),
                URLQueryItem(name: "timeout", value: String(timeoutMilliseconds)),
                URLQueryItem(name: "expected", value: "200-499"),
            ],
            as: [String: Int].self)
    }

    func select(routeName: String, in groupName: String) async throws {
        let body = try encoder.encode(["name": routeName])
        var request = try makeRequest(
            method: "PUT",
            pathComponents: ["proxies", groupName])
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        _ = try await perform(request)
    }

    private func get<Response: Decodable>(
        pathComponents: [String],
        queryItems: [URLQueryItem] = [],
        as type: Response.Type
    ) async throws -> Response {
        let request = try makeRequest(
            method: "GET",
            pathComponents: pathComponents,
            queryItems: queryItems)
        let data = try await perform(request)

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw ClashIntegrationError.incompatibleResponse
        }
    }

    private func makeRequest(
        method: String,
        pathComponents: [String],
        queryItems: [URLQueryItem] = []
    ) throws -> URLRequest {
        var url = configuration.baseURL
        for component in pathComponents {
            url.append(path: component)
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ClashIntegrationError.invalidControllerAddress(url.absoluteString)
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let requestURL = components.url else {
            throw ClashIntegrationError.invalidControllerAddress(url.absoluteString)
        }

        var request = URLRequest(
            url: requestURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 8)
        request.httpMethod = method
        request.setValue("AIQuotaBar/ClashIntegration", forHTTPHeaderField: "User-Agent")
        if !configuration.secret.isEmpty {
            request.setValue(
                "Bearer \(configuration.secret)",
                forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func makeWebSocketRequest(
        pathComponents: [String],
        queryItems: [URLQueryItem]
    ) throws -> URLRequest {
        var request = try makeRequest(
            method: "GET",
            pathComponents: pathComponents,
            queryItems: queryItems)
        guard let requestURL = request.url,
              var components = URLComponents(
                url: requestURL,
                resolvingAgainstBaseURL: false) else {
            throw ClashIntegrationError.invalidControllerAddress(
                request.url?.absoluteString ?? "")
        }

        switch components.scheme?.lowercased() {
        case "http":
            components.scheme = "ws"
        case "https":
            components.scheme = "wss"
        case "ws", "wss":
            break
        default:
            throw ClashIntegrationError.invalidControllerAddress(
                requestURL.absoluteString)
        }

        guard let webSocketURL = components.url else {
            throw ClashIntegrationError.invalidControllerAddress(
                requestURL.absoluteString)
        }
        request.url = webSocketURL
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ClashIntegrationError.incompatibleResponse
            }
            guard (200 ..< 300).contains(httpResponse.statusCode) else {
                let message = (try? decoder.decode(
                    ClashAPIErrorResponse.self,
                    from: data))?.message ?? HTTPURLResponse.localizedString(
                        forStatusCode: httpResponse.statusCode)
                throw ClashIntegrationError.apiFailure(
                    statusCode: httpResponse.statusCode,
                    message: message)
            }
            return data
        } catch let error as ClashIntegrationError {
            throw error
        } catch {
            throw ClashIntegrationError.controllerUnavailable
        }
    }
}

private struct ClashAPIErrorResponse: Decodable {
    let message: String
}
enum ClashOpenAIRouteResolver {
    static func resolveGroupName(
        rules: [ClashRule],
        proxies: [String: ClashProxy]
    ) -> String? {
        let selectors = proxies.filter { _, proxy in
            proxy.type.caseInsensitiveCompare("Selector") == .orderedSame
                && !(proxy.all ?? []).isEmpty
        }

        for rule in rules where isOpenAIRule(rule) {
            if selectors[rule.proxy] != nil {
                return rule.proxy
            }
        }

        return selectors.keys
            .sorted(by: localizedNameOrder)
            .first(where: isLikelyOpenAIGroupName)
    }

    private static func isOpenAIRule(_ rule: ClashRule) -> Bool {
        let type = rule.type
            .lowercased()
            .filter(\.isLetter)
        let payload = rule.payload
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch type {
        case "domain":
            return payload == "openai.com" || payload == "chatgpt.com"
        case "domainsuffix":
            return ["openai.com", "chatgpt.com"].contains { domain in
                domain == payload || domain.hasSuffix(".\(payload)")
            }
        case "domainkeyword":
            return payload.contains("openai") || payload.contains("chatgpt")
        case "ruleset", "geosite":
            return payload == "ai"
                || payload.contains("openai")
                || payload.contains("chatgpt")
                || payload.contains("category-ai")
                || payload.contains("ai-chat")
        default:
            return false
        }
    }

    private static func isLikelyOpenAIGroupName(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        if lowercased.contains("openai")
            || lowercased.contains("chatgpt")
            || lowercased.contains("海外ai")
            || lowercased.contains("人工智能") {
            return true
        }

        guard let expression = try? NSRegularExpression(
            pattern: "(^|[^a-z])ai([^a-z]|$)",
            options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(name.startIndex..., in: name)
        return expression.firstMatch(in: name, range: range) != nil
    }

    private static func localizedNameOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}

enum ClashRouteSorter {
    static func sorted(_ routes: [ClashRoute]) -> [ClashRoute] {
        routes.sorted { lhs, rhs in
            switch (lhs.hasUsableDelay, rhs.hasUsableDelay) {
            case (true, false):
                return true
            case (false, true):
                return false
            case (true, true):
                if lhs.delay != rhs.delay {
                    return (lhs.delay ?? .max) < (rhs.delay ?? .max)
                }
            case (false, false):
                break
            }

            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
