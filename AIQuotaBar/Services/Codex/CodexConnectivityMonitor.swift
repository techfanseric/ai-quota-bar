import Foundation

enum CodexConnectivityState: Equatable, Sendable {
    case unknown
    case reachable
    case unreachable
}

/// Lightweight HTTPS reachability for the two public OpenAI surfaces Codex depends on.
/// Any HTTP response counts as reachable; DNS, connection, and timeout failures do not.
struct CodexConnectivityChecker: Sendable {
    typealias HostProbe = @Sendable (URL) async -> Bool

    static let endpoints = [
        URL(string: "https://chatgpt.com/")!,
        URL(string: "https://openai.com/")!,
    ]

    private let hostProbe: HostProbe

    init(hostProbe: @escaping HostProbe) {
        self.hostProbe = hostProbe
    }

    static func live() -> CodexConnectivityChecker {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)

        return CodexConnectivityChecker { url in
            var request = URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                timeoutInterval: 3)
            request.httpMethod = "HEAD"
            request.setValue("AIQuotaBar/Connectivity", forHTTPHeaderField: "User-Agent")

            do {
                let (_, response) = try await session.data(for: request)
                return response is HTTPURLResponse
            } catch {
                return false
            }
        }
    }

    /// The Codex path is considered unavailable only when neither public host responds.
    func check() async -> CodexConnectivityState {
        await withTaskGroup(of: Bool.self, returning: CodexConnectivityState.self) { group in
            for endpoint in Self.endpoints {
                group.addTask {
                    await hostProbe(endpoint)
                }
            }

            for await isReachable in group where isReachable {
                group.cancelAll()
                return .reachable
            }
            return .unreachable
        }
    }
}

@MainActor
@Observable
final class CodexConnectivityMonitor {
    private(set) var state: CodexConnectivityState = .unknown

    private let checker: CodexConnectivityChecker
    private let delayProvider: @Sendable () -> TimeInterval
    private var monitoringTask: Task<Void, Never>?

    init(
        checker: CodexConnectivityChecker = .live(),
        delayProvider: @escaping @Sendable () -> TimeInterval = {
            jitteredInterval(unitRandom: Double.random(in: 0 ... 1))
        }
    ) {
        self.checker = checker
        self.delayProvider = delayProvider
    }

    func start() {
        guard monitoringTask == nil else { return }

        let checker = checker
        let delayProvider = delayProvider
        monitoringTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let nextState = await checker.check()
                guard !Task.isCancelled else { return }
                guard self != nil else { return }
                self?.state = nextState

                let delay = max(1, delayProvider())
                let nanoseconds = UInt64(delay * 1_000_000_000)
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    nonisolated static func jitteredInterval(unitRandom: Double) -> TimeInterval {
        8 + min(1, max(0, unitRandom)) * 4
    }
}
