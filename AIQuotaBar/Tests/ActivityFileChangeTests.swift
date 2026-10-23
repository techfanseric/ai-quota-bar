import Foundation
import XCTest
@testable import AIQuotaBar

final class TestActivityFileChanges: ActivityFileChangeTracking {
    var next = ActivityFileChanges(requiresFullScan: true, paths: [])
    var alwaysRescan = false
    func consume() -> ActivityFileChanges {
        let result = next
        next = ActivityFileChanges(requiresFullScan: alwaysRescan, paths: [])
        return result
    }
}

final class ActivityFileChangeTests: XCTestCase {
    func testRealWatcherSeesInPlaceWritesNewNestedFilesAndRootRecreation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let watched = root.appendingPathComponent("tasks")
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        let wire = watched.appendingPathComponent("wire.jsonl")
        try Data("start\n".utf8).write(to: wire)
        let monitor = ActivityFileChangeMonitor(roots: [watched])
        XCTAssertTrue(monitor.consume().requiresFullScan)
        // Drain startup notifications before testing the steady-state stream.
        try await Task.sleep(for: .milliseconds(150))
        _ = monitor.consume()
        let handle = try FileHandle(forWritingTo: wire)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("ended\n".utf8))
        try handle.close()
        try await expectChange(monitor, path: wire.path)
        let nested = watched.appendingPathComponent("new/session/output.log")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: nested)
        try await expectChange(monitor, path: nested.path)
        try FileManager.default.removeItem(at: watched)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        try Data("recreated".utf8).write(to: wire)
        try await expectChange(monitor, path: wire.path)
    }

    private func expectChange(_ monitor: ActivityFileChangeMonitor, path: String) async throws {
        for _ in 0..<40 {
            let change = monitor.consume()
            if change.requiresFullScan || change.paths.contains(path) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Filesystem change was not delivered within the existing two-second polling interval: \(path)")
    }
}
