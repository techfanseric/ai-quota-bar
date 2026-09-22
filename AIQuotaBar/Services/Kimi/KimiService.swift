import CodexBarCore
import Foundation

final class KimiService {
    static let shared = KimiService()

    static let webSessionBinding = "kimi.web-session.v1"
    private let defaults: UserDefaults
    private let desktopSession: () throws -> KimiWebSession
    private let webSession: () async throws -> KimiWebSession
    private let webUsage: (KimiWebSession) async throws -> UsageSnapshot
    private let cliAvailable: () -> Bool
    private let desktopAvailable: () -> Bool
    private let browserDiscovery: any KimiBrowserSessionDiscovering
    private let cliStatusProvider: any KimiCLIStatusProviding

    init(
        cliStatusProvider: any KimiCLIStatusProviding = KimiCLIStatusProbe(),
        defaults: UserDefaults = .standard,
        desktopSession: @escaping () throws -> KimiWebSession = { try KimiDesktopSessionReader().load() },
        webSession: @escaping () async throws -> KimiWebSession = {
            guard let stored = await KeychainService.shared.deviceCredential(binding: KimiService.webSessionBinding),
                  let data = stored.data(using: .utf8),
                  let session = try? JSONDecoder().decode(KimiWebSession.self, from: data) else {
                throw KimiSessionError.noBrowserSession
            }
            return try session.validated()
        },
        webUsage: @escaping (KimiWebSession) async throws -> UsageSnapshot = { try await KimiWebUsageClient().fetch($0) },
        cliAvailable: @escaping () -> Bool = { KimiSettingsReader.hasKimiCodeCredential() },
        desktopAvailable: @escaping () -> Bool = { KimiDesktopSessionReader().isPresent },
        browserDiscovery: any KimiBrowserSessionDiscovering = KimiBrowserSessionDiscovery.shared
    ) {
        self.cliStatusProvider = cliStatusProvider
        self.defaults = defaults
        self.desktopSession = desktopSession
        self.webSession = webSession
        self.webUsage = webUsage
        self.cliAvailable = cliAvailable
        self.desktopAvailable = desktopAvailable
        self.browserDiscovery = browserDiscovery
    }

    var hasCLICredential: Bool {
        cliAvailable()
    }

    var sourceMode: KimiDataSourceMode {
        KimiDataSourceMode(rawValue: defaults.string(forKey: KimiDataSourceMode.storageKey) ?? "") ?? .auto
    }

    var hasAutomaticSource: Bool {
        switch sourceMode {
        case .auto:
            return cliAvailable() || desktopAvailable() || browserDiscovery.hasCachedSession
                || defaults.bool(forKey: "kimiSavedWebSessionAvailable")
        case .desktop, .cli, .web: return true // Explicit selections surface sign-in errors.
        }
    }

    /// Called before configured-provider filtering, so a browser-only user is discovered too.
    func discoverAutomaticSources() async {
        guard sourceMode == .auto, !desktopAvailable(), !cliAvailable() else { return }
        do {
            _ = try await webSession()
            defaults.set(true, forKey: "kimiSavedWebSessionAvailable")
        } catch {
            guard !Self.isCancellation(error) else { return }
            defaults.set(false, forKey: "kimiSavedWebSessionAvailable")
            _ = try? await browserDiscovery.sessions()
        }
    }

    func fetchUsage(apiKey: String?) async throws -> UsageData {
        let selected = sourceMode
        let trimmedAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if selected == .auto, !trimmedAPIKey.isEmpty {
            return try await fetchAPIUsage(credential: trimmedAPIKey, source: "Kimi Code API")
        }
        do {
            try Task.checkCancellation()
            switch selected {
            case .auto: return try await fetchAutomaticUsage()
            case .desktop: return try await fetchWebUsage(desktopSession(), source: "Kimi Desktop")
            case .web: return try await fetchWebUsage(webSession(), source: "Kimi Web")
            case .cli: return try await fetchCLIUsage()
            }
        } catch {
            if Self.isCancellation(error) { throw CancellationError() }
            if let error = error as? UsageError { throw error }
            if let error = error as? URLError { throw UsageError.networkError(error) }
            if error is DecodingError { throw UsageError.invalidResponse }
            throw UsageError.apiError(error.localizedDescription)
        }
    }

    private func fetchAutomaticUsage() async throws -> UsageData {
        var localError: Error?
        var desktop: KimiWebSession?
        do { desktop = try desktopSession().validated() }
        catch {
            if Self.isCancellation(error) { throw error }
            if desktopAvailable() { localError = error }
        }
        // Once a valid login is chosen, a network/server error must not jump accounts.
        if let desktop { return try await fetchWebUsage(desktop, source: "Kimi Desktop") }

        var saved: KimiWebSession?
        do { saved = try await webSession().validated() }
        catch { if Self.isCancellation(error) { throw error } }
        defaults.set(saved != nil, forKey: "kimiSavedWebSessionAvailable")
        if let saved { return try await fetchWebUsage(saved, source: "Kimi Web") }

        if cliAvailable() {
            do { return try await fetchCLIUsage() }
            catch {
                if Self.isCancellation(error) { throw error }
                localError = localError ?? error
            }
        }
        let sessions = try await browserDiscovery.sessions()
        if let detected = try KimiBrowserSessionDiscovery.uniqueSession(sessions) {
            return try await fetchWebUsage(detected, source: "Kimi Web (auto)")
        }
        throw localError ?? UsageError.notConfigured
    }

    private func fetchWebUsage(_ session: KimiWebSession, source: String) async throws -> UsageData {
        let snapshot = try await webUsage(session)
        let result = try KimiUsageDataMapper.map(snapshot, source: "\(source) · \(session.origin)",
                                               accountName: session.accountLabel)
        defaults.set(source, forKey: KimiDataSourceMode.lastSuccessfulSourceKey)
        return result
    }

    private func fetchCLIUsage() async throws -> UsageData {
        guard cliAvailable() else { throw UsageError.notConfigured }
        let result = try await KimiUsageDataMapper.map(cliStatusProvider.fetchUsageSnapshot(), source: "Kimi Code CLI /status")
        defaults.set("Kimi Code CLI", forKey: KimiDataSourceMode.lastSuccessfulSourceKey)
        return result
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func fetchAPIUsage(
        credential: String,
        source: String
    ) async throws -> UsageData {
        do {
            let baseURL = try KimiSettingsReader.codeAPIBaseURL()
            let kimiSnapshot = try await KimiUsageFetcher.fetchCodeAPIUsage(
                apiKey: credential,
                baseURL: baseURL)
            let result = try KimiUsageDataMapper.map(
                kimiSnapshot.toUsageSnapshot(),
                source: source)
            defaults.set(source, forKey: KimiDataSourceMode.lastSuccessfulSourceKey)
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as UsageError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw UsageError.networkError(error)
        } catch let error as KimiAPIError {
            throw UsageError.apiError(error.localizedDescription)
        } catch is DecodingError {
            throw UsageError.invalidResponse
        } catch {
            throw UsageError.apiError(error.localizedDescription)
        }
    }

    func testConnection(apiKey: String?) async throws -> Bool {
        _ = try await fetchUsage(apiKey: apiKey)
        return true
    }
}
