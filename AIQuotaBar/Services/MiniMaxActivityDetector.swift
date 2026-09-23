import Foundation

/// Detects active MiniMax coding tasks from both local runtimes:
///
/// - **MiniMax CLI** sessions under `~/.minimax/v2/sessions/<y>/<m>/<d>/`.
///   Read-only: activity is the newest file mtime inside a session directory.
///   `manifest.json` is only used for the canonical session ID — live
///   measurements show it can lag minutes behind actual transcript writes.
/// - **Background tasks** under `~/.minimax/background-tasks/bg_<uuid>/`
///   (how the MiniMax Code desktop app runs tasks). Activity is the mtime of
///   `output.log` / `summary.txt` / the task directory itself.
///
/// Message bodies and tool output are never read.
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
    let backgroundTasksRootURL: URL
    let freshnessWindow: TimeInterval

    init(
        sessionsRootURL: URL = MiniMaxActivityDetector.defaultSessionsRootURL(),
        backgroundTasksRootURL: URL = MiniMaxActivityDetector
            .defaultBackgroundTasksRootURL(),
        freshnessWindow: TimeInterval = MiniMaxActivityDetector
            .defaultFreshnessWindow
    ) {
        self.sessionsRootURL = sessionsRootURL
        self.backgroundTasksRootURL = backgroundTasksRootURL
        self.freshnessWindow = freshnessWindow
    }

    static func defaultHomeURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let configured = environment["MINIMAX_HOME"],
           !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(
            ".minimax",
            isDirectory: true)
    }

    static func defaultSessionsRootURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        defaultHomeURL(environment: environment, homeDirectory: homeDirectory)
            .appendingPathComponent("v2", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    static func defaultBackgroundTasksRootURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        defaultHomeURL(environment: environment, homeDirectory: homeDirectory)
            .appendingPathComponent("background-tasks", isDirectory: true)
    }

    /// Local presence check for task-protection eligibility.
    static func isClientInstalled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Bool {
        let home = defaultHomeURL(environment: environment)
        return fileManager.fileExists(atPath: home.path)
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

        func record(_ prefixedID: String, _ activityAt: Date) {
            activeSessionIDs.insert(prefixedID)
            lastEventBySession[prefixedID] = activityAt
            if lastEventAt == nil || activityAt > lastEventAt! {
                lastEventAt = activityAt
            }
        }

        for sessionDirectory in recentSessionDirectories() {
            guard let activityAt = newestFileModification(
                in: sessionDirectory) else {
                continue
            }
            guard activityAt >= cutoff, activityAt <= now else { continue }
            let sessionID = readSessionID(at: sessionDirectory)
                ?? sessionDirectory.lastPathComponent
            record("minimax:cli:\(sessionID)", activityAt)
        }

        for taskDirectory in backgroundTaskDirectories() {
            guard let activityAt = newestBackgroundTaskModification(
                in: taskDirectory) else {
                continue
            }
            guard activityAt >= cutoff, activityAt <= now else { continue }
            record("minimax:bg:\(taskDirectory.lastPathComponent)", activityAt)
        }

        return ProviderLocalActivitySnapshot(
            activeSessionIDs: activeSessionIDs,
            lastEventAt: lastEventAt,
            lastEventBySession: lastEventBySession)
    }

    // MARK: - CLI sessions

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

    private func readSessionID(at sessionDirectory: URL) -> String? {
        let manifestURL = sessionDirectory
            .appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let object = try? JSONSerialization.jsonObject(
                with: data) as? [String: Any],
              let sessionID = object["sessionId"] as? String,
              !sessionID.isEmpty else {
            return nil
        }
        return sessionID
    }

    // MARK: - Background tasks

    private func backgroundTaskDirectories() -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: backgroundTasksRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries.filter { entry in
            entry.lastPathComponent.hasPrefix("bg_")
                && (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory == true
        }
    }

    // MARK: - Shared helpers

    /// Newest modification time among a directory's immediate entries.
    /// In-place writes do not update the directory's own mtime, so the
    /// entries must be stat'd; the batch prefetch keeps this cheap.
    private func newestFileModification(in directory: URL) -> Date? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else {
            return nil
        }
        return entries.compactMap { entry in
            (try? entry.resourceValues(
                forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }
        .max()
    }

    private func newestBackgroundTaskModification(in directory: URL) -> Date? {
        var dates: [Date] = []
        if let directoryDate = (try? directory.resourceValues(
            forKeys: [.contentModificationDateKey]))?
            .contentModificationDate {
            dates.append(directoryDate)
        }
        for fileName in ["output.log", "summary.txt"] {
            let fileURL = directory.appendingPathComponent(fileName)
            if let fileDate = (try? fileURL.resourceValues(
                forKeys: [.contentModificationDateKey]))?
                .contentModificationDate {
                dates.append(fileDate)
            }
        }
        return dates.max()
    }
}
