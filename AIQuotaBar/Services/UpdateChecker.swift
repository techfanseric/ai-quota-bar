import Foundation

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

final class UpdateChecker {
    static let shared = UpdateChecker()

    private let owner = "techfanseric"
    private let repo = "ai-quota-bar"
    private let defaults = UserDefaults.standard
    private let lastAutomaticCheckAtKey = "lastAutomaticUpdateCheckAt"
    private let lastNotifiedVersionKey = "lastNotifiedUpdateVersion"
    private let githubLatestReleaseURL = URL(string: "https://api.github.com/repos/techfanseric/ai-quota-bar/releases/latest")!
    private let githubLatestRedirectURL = URL(string: "https://github.com/techfanseric/ai-quota-bar/releases/latest")!

    private init() {}

    static var currentAppVersion: String {
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
        let currentVersion = Self.currentAppVersion
        let release = try await latestRelease()

        let latestVersion = normalizeVersionString(release.version)
        let normalizedCurrent = normalizeVersionString(currentVersion)

        if latestVersion.compare(normalizedCurrent, options: [.numeric, .caseInsensitive]) == .orderedDescending {
            return .updateAvailable(
                currentVersion: normalizedCurrent,
                latestVersion: latestVersion,
                releaseURL: release.releaseURL
            )
        }

        return .upToDate(currentVersion: normalizedCurrent)
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
        guard let lastCheck = defaults.object(forKey: lastAutomaticCheckAtKey) as? Date else {
            return true
        }
        return now.timeIntervalSince(lastCheck) >= 24 * 60 * 60
    }

    func markAutomaticCheck(at date: Date = Date()) {
        defaults.set(date, forKey: lastAutomaticCheckAtKey)
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

private struct UpdateRelease {
    let version: String
    let releaseURL: URL
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
