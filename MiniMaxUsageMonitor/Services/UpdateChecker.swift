import Foundation

enum UpdateCheckOutcome {
    case upToDate(currentVersion: String)
    case updateAvailable(currentVersion: String, latestVersion: String, releaseURL: URL)
}

enum UpdateCheckError: LocalizedError {
    case invalidResponse
    case invalidReleaseURL

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid GitHub release response."
        case .invalidReleaseURL:
            return "Invalid release URL."
        }
    }
}

final class UpdateChecker {
    static let shared = UpdateChecker()

    private let owner = "techfanseric"
    private let repo = "minimax-usage-monitor"
    private let defaults = UserDefaults.standard
    private let lastAutomaticCheckAtKey = "lastAutomaticUpdateCheckAt"
    private let lastNotifiedVersionKey = "lastNotifiedUpdateVersion"

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
        let endpoint = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!

        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MiniMaxUsageMonitor", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateCheckError.invalidResponse
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let releaseURL = URL(string: release.htmlURL) else {
            throw UpdateCheckError.invalidReleaseURL
        }

        let latestVersion = normalizeVersionString(release.tagName)
        let normalizedCurrent = normalizeVersionString(currentVersion)

        if latestVersion.compare(normalizedCurrent, options: [.numeric, .caseInsensitive]) == .orderedDescending {
            return .updateAvailable(
                currentVersion: normalizedCurrent,
                latestVersion: latestVersion,
                releaseURL: releaseURL
            )
        }

        return .upToDate(currentVersion: normalizedCurrent)
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

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}
