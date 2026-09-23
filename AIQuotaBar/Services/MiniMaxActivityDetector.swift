import Foundation

/// Detects active MiniMax CLI coding tasks from its local session store.
/// Read-only: each session directory under
/// `~/.minimax/v2/sessions/<year>/<month>/<day>/` carries a `manifest.json`
/// whose `updatedAtMs` the CLI refreshes while a turn is working. Message
/// bodies are never read.
final class MiniMaxActivityDetector: ProviderLocalActivityProviding,
    @unchecked Sendable
{
    static let defaultFreshnessWindow: TimeInterval = 120

    /// How many most-recent day folders (by `YYYY/MM/DD` name) are scanned
    /// each pass. Sessions are created under the day they start, so scanning
    /// the newest two covers anything still working, including across
    /// midnight, without walking the whole history.
    static let scannedDayFolderLimit = 2

    let sessionsRootURL: URL
    let freshnessWindow: TimeInterval

    init(
        sessionsRootURL: URL = MiniMaxActivityDetector.defaultSessionsRootURL(),
        freshnessWindow: TimeInterval = MiniMaxActivityDetector
            .defaultFreshnessWindow
    ) {
        self.sessionsRootURL = sessionsRootURL
        self.freshnessWindow = freshnessWindow
    }

    static func defaultSessionsRootURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let minimaxHome: URL
        if let configured = environment["MINIMAX_HOME"],
           !configured.isEmpty {
            minimaxHome = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            minimaxHome = homeDirectory.appendingPathComponent(
                ".minimax",
                isDirectory: true)
        }
        return minimaxHome
            .appendingPathComponent("v2", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// Local presence check for task-protection eligibility.
    static func isClientInstalled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Bool {
        fileManager.fileExists(
            atPath: defaultSessionsRootURL(environment: environment).path)
    }

    func snapshot() async -> ProviderLocalActivitySnapshot {
        await Task.detached(priority: .utility) { [self] in
            detectSnapshot(now: Date())
        }.value
    }

    func detectSnapshot(now: Date) -> ProviderLocalActivitySnapshot {
        let cutoff = now.addingTimeInterval(-freshnessWindow)
        var activeSessionIDs = Set<String>()
        var lastEventBySession: [String: Date] = [:]
        var lastEventAt: Date?

        for sessionDirectory in recentSessionDirectories() {
            guard let manifest = readManifest(at: sessionDirectory) else {
                continue
            }
            let updatedAt = Date(
                timeIntervalSince1970: manifest.updatedAtMs / 1_000)
            guard updatedAt >= cutoff, updatedAt <= now else { continue }
            let prefixedID = "minimax:cli:\(manifest.sessionID)"
            activeSessionIDs.insert(prefixedID)
            lastEventBySession[prefixedID] = updatedAt
            if lastEventAt == nil || updatedAt > lastEventAt! {
                lastEventAt = updatedAt
            }
        }

        return ProviderLocalActivitySnapshot(
            activeSessionIDs: activeSessionIDs,
            lastEventAt: lastEventAt,
            lastEventBySession: lastEventBySession)
    }

    private func recentSessionDirectories() -> [URL] {
        let dayFolders = sortedDayFolderPaths().prefix(
            Self.scannedDayFolderLimit)
        var directories: [URL] = []
        for dayFolder in dayFolders {
            let dayURL = sessionsRootURL
                .appendingPathComponent(dayFolder, isDirectory: true)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dayURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else {
                continue
            }
            directories.append(contentsOf: entries.filter { entry in
                (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory == true
                    && entry.lastPathComponent.contains("session_")
            })
        }
        return directories
    }

    /// Day folder paths relative to the sessions root, newest first. The
    /// layout is `<year>/<month>/<day>`, so lexicographic ordering of the
    /// joined path matches chronological ordering.
    private func sortedDayFolderPaths() -> [String] {
        guard let yearEntries = try? FileManager.default.contentsOfDirectory(
            at: sessionsRootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else {
            return []
        }
        var paths: [String] = []
        for yearURL in yearEntries {
            let monthRoot = sessionsRootURL
                .appendingPathComponent(yearURL.lastPathComponent)
            guard let monthEntries = try? FileManager.default
                .contentsOfDirectory(
                    at: monthRoot,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]) else {
                continue
            }
            for monthURL in monthEntries {
                let dayRoot = monthRoot
                    .appendingPathComponent(monthURL.lastPathComponent)
                guard let dayEntries = try? FileManager.default
                    .contentsOfDirectory(
                        at: dayRoot,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]) else {
                    continue
                }
                for dayURL in dayEntries {
                    paths.append(
                        "\(yearURL.lastPathComponent)/" +
                        "\(monthURL.lastPathComponent)/" +
                        dayURL.lastPathComponent)
                }
            }
        }
        return paths.sorted(by: >)
    }

    private func readManifest(
        at sessionDirectory: URL
    ) -> SessionManifest? {
        let manifestURL = sessionDirectory
            .appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let object = try? JSONSerialization.jsonObject(
                with: data) as? [String: Any],
              let sessionID = object["sessionId"] as? String,
              !sessionID.isEmpty,
              let updatedAtMs = object["updatedAtMs"] as? NSNumber else {
            return nil
        }
        return SessionManifest(
            sessionID: sessionID,
            updatedAtMs: updatedAtMs.doubleValue)
    }

    private struct SessionManifest {
        let sessionID: String
        let updatedAtMs: Double
    }
}
