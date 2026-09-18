import Foundation
import Observation

enum UpdateCheckOutcome {
    case upToDate(currentVersion: String)
    case updateAvailable(currentVersion: String, latestVersion: String, releaseURL: URL)
}

enum UpdateCheckError: LocalizedError {
    case invalidResponse(String)
    case invalidReleaseURL

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let detail):
            return detail.isEmpty ? "Invalid update response." : "Invalid update response: \(detail)"
        case .invalidReleaseURL:
            return "Invalid release URL."
        }
    }
}

@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    private let owner = "techfanseric"
    private let repo = "ai-quota-bar"
    private let defaults: UserDefaults
    private let currentVersionProvider: () -> String
    private let releaseLoader: (() async throws -> UpdateRelease)?
    private var pendingCheck: Task<UpdateCheckOutcome, Error>?
    private(set) var availableRelease: UpdateRelease?
    private(set) var isChecking = false
    private(set) var lastError: String?
    private(set) var lastCheckedAt: Date?
    private let cachedReleaseKey = "cachedAppUpdateRelease"
    private let lastAttemptKey = "lastAppUpdateAttempt"
    private let lastAutomaticCheckAtKey = "lastAutomaticUpdateCheckAt"
    private let lastNotifiedVersionKey = "lastNotifiedUpdateVersion"
    private let githubLatestReleaseURL = URL(string: "https://api.github.com/repos/techfanseric/ai-quota-bar/releases/latest")!
    private let githubLatestRedirectURL = URL(string: "https://github.com/techfanseric/ai-quota-bar/releases/latest")!

    init(defaults: UserDefaults = .standard,
         currentVersion: @escaping () -> String = { UpdateChecker.currentAppVersion },
         releaseLoader: (() async throws -> UpdateRelease)? = nil) {
        self.defaults = defaults
        self.currentVersionProvider = currentVersion
        self.releaseLoader = releaseLoader
        self.lastCheckedAt = defaults.object(forKey: "lastAutomaticUpdateCheckAt") as? Date
        if let data = defaults.data(forKey: cachedReleaseKey),
           let release = try? JSONDecoder().decode(UpdateRelease.self, from: data),
           Self.isNewer(release.version, than: currentVersion()), release.hasTrustedURLs {
            availableRelease = release
        }
    }

    nonisolated static func isNewer(_ latest: String, than current: String) -> Bool {
        func normalize(_ s: String) -> String {
            let value = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.lowercased().hasPrefix("v") ? String(value.dropFirst()) : value
        }
        return normalize(latest).compare(normalize(current), options: [.numeric, .caseInsensitive]) == .orderedDescending
    }

    nonisolated static var currentAppVersion: String {
        let bundle = Bundle.main
        if let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !short.isEmpty {
            return short
        }

        if let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           !build.isEmpty {
            return build
        }

        return "0.0.0"
    }

    func checkForUpdates() async throws -> UpdateCheckOutcome {
        if let pendingCheck { return try await pendingCheck.value }
        isChecking = true
        lastError = nil
        defaults.set(Date(), forKey: lastAttemptKey)
        let task = Task<UpdateCheckOutcome, Error> {
            let release: UpdateRelease
            if let releaseLoader { release = try await releaseLoader() }
            else { release = try await latestRelease() }
            guard release.hasTrustedURLs else { throw UpdateCheckError.invalidReleaseURL }
            let current = normalizeVersionString(currentVersionProvider())
            if Self.isNewer(release.version, than: current) {
                availableRelease = release
                defaults.set(try JSONEncoder().encode(release), forKey: cachedReleaseKey)
                return .updateAvailable(currentVersion: current, latestVersion: normalizeVersionString(release.version), releaseURL: release.releaseURL)
            }
            availableRelease = nil
            defaults.removeObject(forKey: cachedReleaseKey)
            return .upToDate(currentVersion: current)
        }
        pendingCheck = task
        defer { pendingCheck = nil; isChecking = false }
        do {
            let result = try await task.value
            lastCheckedAt = Date()
            defaults.set(lastCheckedAt, forKey: lastAutomaticCheckAtKey)
            return result
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func checkIfNeeded() async {
        guard shouldRunAutomaticDailyCheck() else { return }
        _ = try? await checkForUpdates()
    }

    private func latestRelease() async throws -> UpdateRelease {
        var errors: [String] = []

        do {
            return try await fetchCloudUpdateManifest()
        } catch {
            errors.append("cloud: \(error.localizedDescription)")
        }

        do {
            return try await fetchGitHubAPIRelease()
        } catch {
            errors.append("github-api: \(error.localizedDescription)")
        }

        do {
            return try await fetchGitHubRedirectRelease()
        } catch {
            errors.append("github-redirect: \(error.localizedDescription)")
        }

        throw UpdateCheckError.invalidResponse(errors.joined(separator: "; "))
    }

    private func fetchCloudUpdateManifest() async throws -> UpdateRelease {
        guard var components = URLComponents(string: CloudSyncSettings.defaultEndpointURLString) else {
            throw UpdateCheckError.invalidResponse("cloud update endpoint is invalid")
        }
        components.path = "/v1/app-update"
        components.query = nil
        guard let endpoint = components.url else {
            throw UpdateCheckError.invalidResponse("cloud update endpoint is invalid")
        }

        var request = URLRequest(url: endpoint)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AIQuotaBar", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse("cloud update response is not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdateCheckError.invalidResponse("cloud update HTTP \(http.statusCode)")
        }

        let manifest = try JSONDecoder().decode(CloudUpdateManifest.self, from: data)
        guard let releaseURL = URL(string: manifest.releaseURL) else {
            throw UpdateCheckError.invalidReleaseURL
        }
        return UpdateRelease(version: manifest.version, releaseURL: releaseURL)
    }

    private func fetchGitHubAPIRelease() async throws -> UpdateRelease {
        var request = URLRequest(url: githubLatestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AIQuotaBar", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse("GitHub response is not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdateCheckError.invalidResponse("GitHub HTTP \(http.statusCode)")
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let releaseURL = URL(string: release.htmlURL) else {
            throw UpdateCheckError.invalidReleaseURL
        }
        return UpdateRelease(version: release.tagName, releaseURL: releaseURL)
    }

    private func fetchGitHubRedirectRelease() async throws -> UpdateRelease {
        var request = URLRequest(url: githubLatestRedirectURL)
        request.setValue("AIQuotaBar", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let finalURL = response.url else {
            throw UpdateCheckError.invalidReleaseURL
        }
        let tag = finalURL.lastPathComponent
        guard !tag.isEmpty, finalURL.absoluteString.contains("/releases/tag/") else {
            throw UpdateCheckError.invalidReleaseURL
        }
        return UpdateRelease(version: tag, releaseURL: finalURL)
    }

    func shouldRunAutomaticDailyCheck(now: Date = Date()) -> Bool {
        if let attempt = defaults.object(forKey: lastAttemptKey) as? Date,
           now.timeIntervalSince(attempt) < 15 * 60 { return false }
        guard let lastCheck = defaults.object(forKey: lastAutomaticCheckAtKey) as? Date else {
            return true
        }
        return now.timeIntervalSince(lastCheck) >= 24 * 60 * 60
    }

    func shouldNotifyUpdate(latestVersion: String) -> Bool {
        let normalizedLatest = normalizeVersionString(latestVersion)
        guard let lastNotified = defaults.string(forKey: lastNotifiedVersionKey) else {
            return true
        }
        return normalizeVersionString(lastNotified) != normalizedLatest
    }

    func markNotifiedUpdate(latestVersion: String) {
        defaults.set(normalizeVersionString(latestVersion), forKey: lastNotifiedVersionKey)
    }

    private func normalizeVersionString(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("v") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }
}

struct UpdateRelease: Codable {
    let version: String
    let releaseURL: URL
    var downloadURL: URL { URL(string: "https://github.com/techfanseric/ai-quota-bar/releases/download/")!.appendingPathComponent(releaseURL.lastPathComponent).appendingPathComponent("AIQuotaBar.dmg") }
    var changelogURL: URL { URL(string: "https://ai-quota-bar.pages.dev/changelog#\(version.hasPrefix("v") ? version : "v" + version)")! }
    var hasTrustedURLs: Bool {
        releaseURL.scheme == "https" && releaseURL.host == "github.com"
            && releaseURL.path.hasPrefix("/techfanseric/ai-quota-bar/releases/tag/")
    }
}

private struct CloudUpdateManifest: Decodable {
    let version: String
    let releaseURL: String

    enum CodingKeys: String, CodingKey {
        case version
        case releaseURL = "release_url"
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}
