import Foundation
import CoreServices

struct ActivityFileChanges {
    var requiresFullScan: Bool
    var paths: Set<String>
}

protocol ActivityFileChangeTracking: AnyObject {
    func consume() -> ActivityFileChanges
}

/// One recursive FSEvents stream replaces thousands of per-directory probes.
/// Only paths are retained. Dropped events and a stopped watcher fail open to
/// polling; callers also periodically reconcile the filesystem in full.
final class ActivityFileChangeMonitor: ActivityFileChangeTracking {
    private final class State {
        let lock = NSLock()
        let roots: [String]
        var full = true
        var failed = false
        var paths = Set<String>()
        init(roots: [String]) { self.roots = roots }

        func receive(_ paths: [String], flags: UnsafePointer<FSEventStreamEventFlags>) {
            lock.lock()
            defer { lock.unlock() }
            let resetFlags = UInt32(kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
            for (index, rawPath) in paths.enumerated() {
                // A watch anchor can disappear too; until restart, use polling.
                if flags[index] & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
                    failed = true
                }
                if flags[index] & resetFlags != 0 { full = true }
                // FSEvents uses /private/var while Foundation listings can use
                // /var. Normalize both sides before matching or caching paths.
                let path = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path
                if roots.contains(path), flags[index] & UInt32(
                    kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                    | kFSEventStreamEventFlagItemRenamed) != 0 { full = true }
                guard roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
                self.paths.insert(path)
                if self.paths.count > 4096 {
                    self.paths.removeAll(keepingCapacity: true)
                    full = true
                }
            }
        }
    }

    private let state: State
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "aiquotabar.activity-file-events", qos: .utility)

    init(roots: [URL]) {
        let paths = roots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        state = State(roots: paths)
        // Watch a surviving ancestor so missing roots and root replacement are
        // detected without opening one descriptor for every historical session.
        let anchors = Set(roots.map { root -> String in
            var anchor = root.deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: anchor.path), anchor.path != "/" {
                anchor.deleteLastPathComponent()
            }
            return anchor.resolvingSymlinksInPath().path
        })
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(state).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<State>.fromOpaque(info).retain()
                return UnsafeRawPointer(info)
            },
            release: { info in
                if let info { Unmanaged<State>.fromOpaque(info).release() }
            }, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let state = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as! [String]
            state.receive(Array(paths.prefix(count)), flags: flags)
        }, &context, Array(anchors) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        0.05, FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot))
        guard let stream else { state.failed = true; return }
        FSEventStreamSetDispatchQueue(stream, queue)
        if !FSEventStreamStart(stream) { state.failed = true }
    }

    func consume() -> ActivityFileChanges {
        state.lock.lock()
        defer { state.lock.unlock() }
        let result = ActivityFileChanges(requiresFullScan: state.full || state.failed, paths: state.paths)
        state.full = false
        state.paths.removeAll(keepingCapacity: true)
        return result
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
