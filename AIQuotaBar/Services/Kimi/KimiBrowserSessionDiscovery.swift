import CodexBarCore
import Foundation

protocol KimiBrowserSessionDiscovering: Sendable {
    var hasCachedSession: Bool { get }
    func sessions() async throws -> [KimiWebSession]
}

/// Background detection never requests browser Keychain UI. Positive and negative
/// results are cached, and concurrent refreshes share the same scan.
final class KimiBrowserSessionDiscovery: KimiBrowserSessionDiscovering, @unchecked Sendable {
    static let shared = KimiBrowserSessionDiscovery()
    private let lock = NSLock()
    private var cached: [KimiWebSession] = []
    private var expiresAt = Date.distantPast
    private var inFlight: Task<[KimiWebSession], Never>?
    private var scanID: UUID?
    private let scan: @Sendable () -> [KimiWebSession]
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 300, scan: @escaping @Sendable () -> [KimiWebSession] = {
        ProviderInteractionContext.$current.withValue(.background) {
            let imported = (try? KimiCookieImporter.importSessions()) ?? []
            return imported.flatMap { entry in
                entry.cookies.compactMap { cookie -> KimiWebSession? in
                    guard cookie.name == "kimi-auth",
                          cookie.expiresDate.map({ $0 > Date() }) ?? true else { return nil }
                    return try? KimiWebSession(token: cookie.value, origin: "https://www.kimi.com").validated()
                }
            }
        }
    }) {
        self.ttl = ttl
        self.scan = scan
    }

    var hasCachedSession: Bool {
        lock.withLock { cached.contains { (try? $0.validated()) != nil } }
    }

    func sessions() async throws -> [KimiWebSession] {
        try Task.checkCancellation()
        let work = lock.withLock { () -> (task: Task<[KimiWebSession], Never>, id: UUID?) in
            if let inFlight { return (inFlight, scanID) }
            if Date() < expiresAt {
                let values = cached
                return (Task { values }, nil)
            }
            let scan = self.scan
            let task = Task.detached(priority: .utility) { scan() }
            inFlight = task
            scanID = UUID()
            return (task, scanID)
        }
        let values = await work.task.value
        try Task.checkCancellation()
        return lock.withLock {
            // A cached read must not extend the scan TTL.
            if let id = work.id, id == scanID {
                cached = values
                expiresAt = Date().addingTimeInterval(ttl)
                inFlight = nil
                scanID = nil
            }
            return values.filter { (try? $0.validated()) != nil }
        }
    }

    static func uniqueSession(_ sessions: [KimiWebSession]) throws -> KimiWebSession? {
        var accounts: [String: KimiWebSession] = [:]
        for session in sessions {
            guard (try? session.validated()) != nil else { continue }
            let key = session.origin + "|" + (session.accountID ?? session.token)
            // Keep the freshest session if one account appears in multiple profiles.
            if let previous = accounts[key],
               (previous.expiry ?? .distantPast) >= (session.expiry ?? .distantPast) { continue }
            accounts[key] = session
        }
        guard accounts.count <= 1 else { throw KimiSessionError.multipleBrowserAccounts }
        return accounts.values.first
    }
}
