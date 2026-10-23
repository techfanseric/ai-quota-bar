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

    /// Events keep activity current; this reconciliation also recovers from
    /// changes that the filesystem fails to report.
    static let defaultFullBackgroundSweepInterval: TimeInterval = 300

    let sessionsRootURL: URL
    let backgroundTasksRootURL: URL
    let freshnessWindow: TimeInterval
    let fullBackgroundSweepInterval: TimeInterval

    private let directoryCache = ActivityDirectoryCache()
    private let lock = NSLock()
    private let changeSource: ActivityFileChangeTracking
    private var cliActivityCache: [String: (id: String, activity: Date)] = [:]
    private(set) var backgroundProbeCount = 0
    /// Newest known activity time per background-task directory.
    private var backgroundActivityCache: [String: Date] = [:]
    private var lastFullBackgroundSweep = Date.distantPast

    init(
        sessionsRootURL: URL = MiniMaxActivityDetector.defaultSessionsRootURL(),
        backgroundTasksRootURL: URL = MiniMaxActivityDetector
            .defaultBackgroundTasksRootURL(),
        freshnessWindow: TimeInterval = MiniMaxActivityDetector
            .defaultFreshnessWindow,
        fullBackgroundSweepInterval: TimeInterval = MiniMaxActivityDetector
            .defaultFullBackgroundSweepInterval,
        changeSource: ActivityFileChangeTracking? = nil
    ) {
        self.sessionsRootURL = sessionsRootURL.resolvingSymlinksInPath().standardizedFileURL
        self.backgroundTasksRootURL = backgroundTasksRootURL.resolvingSymlinksInPath().standardizedFileURL
        self.changeSource = changeSource ?? ActivityFileChangeMonitor(
            roots: [self.sessionsRootURL, self.backgroundTasksRootURL])
        self.freshnessWindow = freshnessWindow
        self.fullBackgroundSweepInterval = fullBackgroundSweepInterval
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
        lock.lock()
        defer { lock.unlock() }
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

        let changes = changeSource.consume()
        let fullSweep = changes.requiresFullScan
            || now < lastFullBackgroundSweep
            || now.timeIntervalSince(lastFullBackgroundSweep) >= fullBackgroundSweepInterval
        if fullSweep { lastFullBackgroundSweep = now }

        let cliRoot = sessionsRootURL.path
        if fullSweep || changes.paths.contains(where: { $0 == cliRoot || $0.hasPrefix(cliRoot + "/") }) {
            var latest: [String: (id: String, activity: Date)] = [:]
            for session in recentSessionDirectories() {
                guard let activity = newestFileModification(in: session) else { continue }
                latest[session.path] = (readSessionID(at: session) ?? session.lastPathComponent, activity)
            }
            cliActivityCache = latest
        }
        for entry in cliActivityCache.values where entry.activity >= cutoff && entry.activity <= now {
            record("minimax:cli:\(entry.id)", entry.activity)
        }

        let backgroundRoot = backgroundTasksRootURL.path
        if fullSweep {
            var latest: [String: Date] = [:]
            for entry in directoryCache.entries(at: backgroundTasksRootURL)
            where entry.isDirectory && entry.name.hasPrefix("bg_") {
                if let date = probeBackgroundTask(atPath: entry.path) { latest[entry.path] = date }
            }
            backgroundActivityCache = latest
        } else {
            // A write to an old output.log does not touch its directory's
            // mtime. File events identify that task directly, so even resumed
            // historical tasks are seen on the next two-second poll.
            var dirty = Set<String>()
            for path in changes.paths where path.hasPrefix(backgroundRoot + "/") {
                let relative = path.dropFirst(backgroundRoot.count + 1)
                guard let name = relative.split(separator: "/").first, name.hasPrefix("bg_") else { continue }
                dirty.insert(backgroundRoot + "/" + name)
            }
            for path in dirty {
                backgroundActivityCache[path] = probeBackgroundTask(atPath: path)
            }
            if dirty.isEmpty, changes.paths.contains(backgroundRoot) {
                let entries = directoryCache.entries(at: backgroundTasksRootURL)
                    .filter { $0.isDirectory && $0.name.hasPrefix("bg_") }
                let livePaths = Set(entries.map(\.path))
                backgroundActivityCache = backgroundActivityCache.filter { livePaths.contains($0.key) }
                for entry in entries where backgroundActivityCache[entry.path] == nil {
                    backgroundActivityCache[entry.path] = probeBackgroundTask(atPath: entry.path)
                }
            }
        }
        for (path, activity) in backgroundActivityCache where activity >= cutoff && activity <= now {
            record("minimax:bg:\(path.split(separator: "/").last!)", activity)
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
            directories.append(contentsOf: directoryCache.entries(at: dayURL)
                .filter { $0.isDirectory && $0.name.contains("session_") }
                .map(\.url))
        }
        return directories
    }

    /// Day folder paths relative to the sessions root, newest first. The
    /// layout is `<year>/<month>/<day>`, so lexicographic ordering of the
    /// joined path matches chronological ordering.
    private func sortedDayFolderPaths() -> [String] {
        var paths: [String] = []
        for year in directoryCache.entries(at: sessionsRootURL) where year.isDirectory {
            for month in directoryCache.entries(atPath: year.path) where month.isDirectory {
                for day in directoryCache.entries(atPath: month.path) where day.isDirectory {
                    paths.append("\(year.name)/\(month.name)/\(day.name)")
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

    private func probeBackgroundTask(atPath path: String) -> Date? {
        backgroundProbeCount += 1
        // A removed task must disappear, even if a stale cached path remains.
        guard let modified = ActivityDirectoryCache.modificationDate(atPath: path) else { return nil }
        return newestBackgroundTaskModification(atPath: path, directoryModifiedAt: modified)
    }

    // MARK: - Shared helpers

    /// Newest modification time among a directory's immediate entries.
    /// In-place writes do not update the directory's own mtime, so the
    /// entries must be stat'd even when membership comes from the cache.
    private func newestFileModification(in directory: URL) -> Date? {
        directoryCache.entries(at: directory)
            .compactMap { ActivityDirectoryCache.modificationDate(atPath: $0.path) }
            .max()
    }

    /// Newest of the directory's own mtime,
    /// `output.log`, and `summary.txt`. The two probe files are stat'd with
    /// plain string paths — building `URL`s and resolving per-URL resource
    /// values costs far more than the stats themselves once the root holds
    /// thousands of historical task folders.
    private func newestBackgroundTaskModification(
        atPath directoryPath: String,
        directoryModifiedAt: Date?
    ) -> Date? {
        var dates: [Date] = []
        if let directoryModifiedAt {
            dates.append(directoryModifiedAt)
        }
        for fileName in ["output.log", "summary.txt"] {
            if let fileDate = Self.modificationDateIfExists(
                atPath: directoryPath + "/" + fileName) {
                dates.append(fileDate)
            }
        }
        return dates.max()
    }

    /// Direct POSIX stat: most historical task folders hold neither probe
    /// file, and `FileManager.attributesOfItem` pays an ObjC exception
    /// raise/catch for each miss — across thousands of folders that alone
    /// saturated a core. A raw `stat` call is a single microsecond syscall.
    private static func modificationDateIfExists(atPath path: String) -> Date? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        return Date(
            timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)
                + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000)
    }
}
