import Foundation
import Darwin

/// Cache directory membership, never child contents or modification dates.
/// A transcript can change in place without touching its parent directory.
/// Callers serialize access along with their detector state.
final class ActivityDirectoryCache {
    struct Entry {
        let url: URL
        let path: String
        let name: String
        let isDirectory: Bool
    }

    private struct Stamp: Equatable {
        let device: dev_t
        let inode: ino_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ value: stat) {
            device = value.st_dev
            inode = value.st_ino
            modifiedSeconds = value.st_mtimespec.tv_sec
            modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec
            changedNanoseconds = value.st_ctimespec.tv_nsec
        }
    }

    private var cached: [String: (stamp: Stamp, entries: [Entry])] = [:]

    func entries(at directory: URL) -> [Entry] {
        entries(atPath: directory.path)
    }

    func entries(atPath path: String) -> [Entry] {
        var info = stat()
        guard stat(path, &info) == 0 else {
            cached.removeValue(forKey: path)
            return []
        }
        let stamp = Stamp(info)
        if let existing = cached[path], existing.stamp == stamp {
            return existing.entries
        }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            cached.removeValue(forKey: path)
            return []
        }
        let entries = urls.map { url in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let normalized = url.resolvingSymlinksInPath()
            return Entry(url: normalized, path: normalized.path, name: url.lastPathComponent,
                         isDirectory: isDirectory)
        }
        // Never retain an unbounded history of removed session directories.
        if cached.count >= 4096 { cached.removeAll(keepingCapacity: true) }
        cached[path] = (stamp, entries)
        return entries
    }

    static func modificationDate(at url: URL) -> Date? {
        modificationDate(atPath: url.path)
    }

    static func modificationDate(atPath path: String) -> Date? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
            + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }
}
