import Foundation

struct MagpieModelActivitySnapshot: Equatable, Sendable {
    struct Request: Equatable, Sendable {
        let id: Int64
        let provider: UsageProvider
        let model: String
        var sessionID: String? = nil
        /// 服务这条请求的账号（邮箱，小写）。仅 provider 级的路由有值。
        ///
        /// Codex 当前登录着的那个账号与网关共用 rest id `codex`，但 seat 的
        /// `who` 仍说出它是哪个邮箱 —— 所以**单个在途请求是可以唯一归属到
        /// 账号的**，不必依赖车道计数来反推。
        var accountKey: String? = nil
    }
    var isConfigured: Bool
    var isAvailable: Bool
    var providerIDs: Set<String>
    var requests: [Request]
    /// 每个账号/Key 此刻在流转的请求数，按网关自己的车道记账。
    ///
    /// 键是 `provider@account`（账号）或 `provider#keyid`（Key）。
    /// 空键 `codex` 是 Codex **当前登录着**的那个账号 —— 它与网关共用 rest id，
    /// 不可区分是哪个邮箱，见 `MagpieAccountUsage`。
    var lanes: [String: Int] = [:]

    static let disabled = Self(
        isConfigured: false, isAvailable: false, providerIDs: [], requests: [])
}

protocol MagpieModelActivityProviding: Sendable {
    func snapshot() async -> MagpieModelActivitySnapshot
}

/// Reads only the existing local gateway used by Codex. No API key, cookie,
/// vendor request, full prompt endpoint, or remote host is used. Decoding
/// keeps route identity/destination only; other trace fields are discarded.
actor MagpieModelActivityDetector: MagpieModelActivityProviding {
    struct Endpoint: Equatable, Sendable {
        let url: URL
        let providerIDs: Set<String>
    }

    private struct Concurrency: Decodable {
        struct Active: Decodable {
            let id: Int64
            let agent: String
            let phase: String?
            let route: Int64?
            let session: String?
        }
        /// 一个账号/Key 的车道：此刻在厂商侧流转的请求数与排队数。
        struct Lane: Decodable {
            let busy: Int
            let waiting: Int?
        }
        let object: String
        let active: [Active]
        let data: [String: Lane]?
    }

    struct Trace: Decodable {
        struct Route: Decodable {
            struct Try: Decodable {
                let id: String
                let model: String?
                let served: String?
                let done: Bool
            }
            struct Seat: Decodable {
                let id: String
                let provider: String
                let model: String
                /// 账号身份（邮箱）或 Key 名。`codex@user` 的 seat 才有。
                let who: String?
                /// "account" / "key" / "provider"。
                let kind: String?
            }
            let id: Int64
            let done: Bool
            let tries: [Try]
            let order: [Seat]
        }
        let object: String
        let routes: [Route]
        let seq: Int64?
        let pid: Int?
    }

    private let configURL: URL
    private let session: URLSession
    private let redirectGuard = NoRedirects()
    private var cachedEndpoint: URL?
    private var sequence: Int64 = 0
    private var ownerPID: Int?
    private var liveRoutes: [Int64: Trace.Route] = [:]

    init(configURL: URL? = nil, session: URLSession? = nil) {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        self.configURL = configURL ?? home.appendingPathComponent("config.toml")
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.urlCache = nil
            config.timeoutIntervalForRequest = 1.5
            config.timeoutIntervalForResource = 3
            self.session = URLSession(configuration: config)
        }
    }

    /// A deliberately narrow reader for standard model_providers sections.
    /// Unsupported TOML syntax disables discovery, never guesses a host.
    static func endpoint(in config: String) -> Endpoint? {
        var section: String?
        var urls: [URL: Set<String>] = [:]
        for raw in config.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                section = nil
                if line.hasSuffix("]"), line.hasPrefix("[model_providers.") {
                    let value = String(line.dropFirst("[model_providers.".count).dropLast())
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if !value.isEmpty, !value.contains(".") { section = value.lowercased() }
                }
            }
            guard let owner = section,
                  let equals = line.firstIndex(of: "="),
                  line[..<equals].trimmingCharacters(in: .whitespaces) == "base_url" else { continue }
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard let quote = value.first, quote == "\"" || quote == "'",
                  let end = value.dropFirst().firstIndex(of: quote),
                  let url = loopbackRoot(String(value[value.index(after: value.startIndex)..<end]))
            else { continue }
            urls[url, default: []].insert(owner)
        }
        // Do not merge different local gateways' request namespaces.
        if let item = urls.first(where: { $0.value.contains("magpie") }) {
            return Endpoint(url: item.key, providerIDs: item.value)
        }
        guard urls.count == 1, let item = urls.first else { return nil }
        return Endpoint(url: item.key, providerIDs: item.value)
    }

    static func loopbackRoot(_ raw: String) -> URL? {
        guard var parts = URLComponents(string: raw),
              parts.scheme == "http" || parts.scheme == "https",
              ["127.0.0.1", "localhost", "[::1]", "::1"].contains(parts.host?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.query == nil,
              parts.fragment == nil, ["", "/", "/v1", "/v1/"].contains(parts.path)
        else { return nil }
        if parts.host?.lowercased() == "localhost" { parts.host = "127.0.0.1" }
        parts.path = ""
        return parts.url
    }

    func snapshot() async -> MagpieModelActivitySnapshot {
        guard let data = try? Data(contentsOf: configURL), data.count <= 1_048_576,
              let text = String(data: data, encoding: .utf8),
              let endpoint = Self.endpoint(in: text) else {
            resetRoutes()
            cachedEndpoint = nil
            return .disabled
        }
        var out = MagpieModelActivitySnapshot(
            isConfigured: true, isAvailable: false, providerIDs: endpoint.providerIDs, requests: [])
        if cachedEndpoint != endpoint.url {
            resetRoutes()
            cachedEndpoint = endpoint.url
        }
        do {
            let active = try await read(endpoint.url, path: "v1/magpie/concurrency", limit: 1 << 20)
            let concurrency = try JSONDecoder().decode(Concurrency.self, from: active)
            guard concurrency.object == "concurrency" else { throw ReadError.invalid }
            // 车道属于 concurrency，不属于 trace。即使没有可归属到 trace
            // seat 的请求，也必须保留它：网关自己的按账号 busy 计数正是
            // trace 尚未落座时最可靠的账号级证据。
            out.lanes = Self.lanes(from: concurrency)
            if !concurrency.active.contains(where: { Self.isCodex($0.agent) && $0.phase == "upstream" }) {
                resetRoutes()
                out.isAvailable = true
                return out
            }
            let data = try await read(endpoint.url, path: "v1/magpie/trace", limit: 8 << 20, after: sequence)
            let trace = try JSONDecoder().decode(Trace.self, from: data)
            guard trace.object == "trace" else { throw ReadError.invalid }
            if let previous = ownerPID, let pid = trace.pid, previous != pid {
                resetRoutes()
                return out // next read asks the new owner for a full snapshot
            }
            if let seq = trace.seq, seq < sequence { liveRoutes.removeAll() }
            ownerPID = trace.pid
            for route in trace.routes {
                if route.done { liveRoutes.removeValue(forKey: route.id) }
                else { liveRoutes[route.id] = route }
            }
            let activeIDs = Set(concurrency.active.compactMap(\.route))
            liveRoutes = liveRoutes.filter { activeIDs.contains($0.key) }
            sequence = trace.seq ?? 0
            out.requests = Self.requests(active: concurrency, routes: liveRoutes)
            out.isAvailable = true
        } catch { resetRoutes() }
        return out
    }

    private func resetRoutes() {
        sequence = 0
        ownerPID = nil
        liveRoutes.removeAll()
    }

    static func requests(concurrency: Data, trace: Data) throws -> [MagpieModelActivitySnapshot.Request] {
        let active = try JSONDecoder().decode(Concurrency.self, from: concurrency)
        let state = try JSONDecoder().decode(Trace.self, from: trace)
        guard active.object == "concurrency", state.object == "trace" else { throw ReadError.invalid }
        var routes: [Int64: Trace.Route] = [:]
        for route in state.routes { routes[route.id] = route }
        return requests(active: active, routes: routes)
    }

    /// 从原始 JSON 解出完整的活动快照（含车道），供测试与离线核对使用。
    static func snapshot(concurrency: Data, trace: Data) throws -> MagpieModelActivitySnapshot {
        let active = try JSONDecoder().decode(Concurrency.self, from: concurrency)
        let state = try JSONDecoder().decode(Trace.self, from: trace)
        guard active.object == "concurrency", state.object == "trace" else { throw ReadError.invalid }
        var routes: [Int64: Trace.Route] = [:]
        for route in state.routes { routes[route.id] = route }
        return MagpieModelActivitySnapshot(
            isConfigured: true,
            isAvailable: true,
            providerIDs: [],
            requests: requests(active: active, routes: routes),
            lanes: lanes(from: active))
    }

    /// 网关自己的车道记账：每个账号/Key 此刻在流转的请求数。
    ///
    /// 这是**账号级**的实时证据，与 trace 的 rest id 不同 —— trace 里
    /// Codex 当前登录着的账号与网关共用 `codex`，车道里却是 `codex@user`。
    private static func lanes(from concurrency: Concurrency) -> [String: Int] {
        var out: [String: Int] = [:]
        for (who, lane) in concurrency.data ?? [:] where lane.busy > 0 {
            out[who] = lane.busy
        }
        return out
    }

    private static func requests(active: Concurrency, routes: [Int64: Trace.Route])
        -> [MagpieModelActivitySnapshot.Request] {
        var seen = Set<Int64>()
        return active.active.compactMap { request in
            guard seen.insert(request.id).inserted, Self.isCodex(request.agent),
                  request.phase == "upstream", let routeID = request.route,
                  let route = routes[routeID], !route.done,
                  let attempt = route.tries.last(where: { !$0.done }),
                  let model = attempt.model,
                  let seat = route.order.first(where: { $0.id == attempt.id && $0.model == model }),
                  let safeModel = CodexTaskMetadataSanitizer.sanitize(
                    attempt.served.flatMap { $0.isEmpty ? nil : $0 } ?? model),
                  let provider = ModelActivityAttribution.provider(model: safeModel, provider: seat.provider)
            else { return nil }
            return .init(id: request.id, provider: provider, model: safeModel,
                sessionID: request.session,
                // 只认订阅账号的 seat：Key 的 who 是 Key 名，不是邮箱。
                accountKey: seat.kind == "account"
                    ? seat.who?.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    : nil)
        }
    }

    private static func isCodex(_ agent: String) -> Bool {
        ["codex", "codex-desktop", "codex-app"].contains(agent.lowercased())
    }

    private func read(_ root: URL, path: String, limit: Int, after: Int64 = 0) async throws -> Data {
        var url = root.appendingPathComponent(path)
        if after > 0, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.queryItems = [URLQueryItem(name: "after", value: String(after))]
            if let changed = parts.url { url = changed }
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 1.5
        let (bytes, response) = try await session.bytes(for: request, delegate: redirectGuard)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= limit else { throw ReadError.invalid }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw ReadError.invalid }
            data.append(byte)
        }
        return data
    }

    private enum ReadError: Error { case invalid }
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}
