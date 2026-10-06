import Foundation

/// Removes the installer package that installed this app, once the app is
/// running in the user's own session.
///
/// The installer's own cleanup job cannot do this part. `~/Downloads` carries a
/// `group:everyone deny delete` ACL that macOS enforces against root and
/// against daemons with no attributed user session, so the file the user
/// actually downloaded can only be unlinked by a process inside that session.
/// The installer therefore drops a record and the app picks it up on launch.
enum InstallerCleanup {
    /// Written by the installer's postinstall, owned by the console user so the
    /// app is allowed to read and remove it again.
    static let pendingRecordPath = "/private/var/tmp/aiquotabar-installer-pending"

    /// Only this exact file name is ever removed.
    static let removableFileName = "AIQuotaBar.pkg"

    /// A record older than this is treated as stale and dropped, so a leftover
    /// from an install that never reached the app cannot delete something much
    /// later.
    static let recordMaxAge: TimeInterval = 15 * 60

    /// Line based on purpose: the first line is a unix timestamp, the rest are
    /// absolute paths. Avoids JSON escaping for paths that may contain quotes.
    static func encodeRecord(paths: [String], writtenAt: Date) -> String {
        ([String(Int(writtenAt.timeIntervalSince1970))] + paths).joined(separator: "\n") + "\n"
    }

    static func decodeRecord(_ contents: String) -> (writtenAt: Date, paths: [String])? {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let first = lines.first, let stamp = TimeInterval(first) else { return nil }
        return (Date(timeIntervalSince1970: stamp), Array(lines.dropFirst()))
    }

    /// Removes the recorded installer files and the record itself.
    /// - Returns: the paths that were actually removed, for logging and tests.
    @discardableResult
    static func performPendingRemoval(
        recordPath: String = pendingRecordPath,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> [String] {
        defer { try? fileManager.removeItem(atPath: recordPath) }

        guard let contents = try? String(contentsOfFile: recordPath, encoding: .utf8),
              let record = decodeRecord(contents) else { return [] }

        guard now.timeIntervalSince(record.writtenAt) <= recordMaxAge else { return [] }

        var removed: [String] = []
        for path in record.paths where (path as NSString).lastPathComponent == removableFileName {
            guard fileManager.fileExists(atPath: path) else { continue }
            guard (try? fileManager.removeItem(atPath: path)) != nil else { continue }
            removed.append(path)
        }
        return removed
    }
}