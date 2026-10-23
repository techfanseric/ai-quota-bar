import Foundation
import XCTest
@testable import AIQuotaBar

final class ActivityDirectoryCacheTests: XCTestCase {
    func testMembershipTracksNestedCreationRemovalAndReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ActivityDirectoryCache()
        XCTAssertTrue(cache.entries(at: root).isEmpty)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = root.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        XCTAssertEqual(cache.entries(at: root).map(\.url.lastPathComponent), ["session"])
        XCTAssertTrue(cache.entries(at: session).isEmpty)
        let wire = session.appendingPathComponent("wire.jsonl")
        try Data("start".utf8).write(to: wire)
        XCTAssertEqual(cache.entries(at: session).map(\.url.lastPathComponent), ["wire.jsonl"])
        try FileManager.default.removeItem(at: session)
        XCTAssertTrue(cache.entries(at: root).isEmpty)
        XCTAssertTrue(cache.entries(at: session).isEmpty)
        // Recreate the same path as a file: neither inode nor type may stick.
        try Data().write(to: session)
        XCTAssertFalse(try XCTUnwrap(cache.entries(at: root).first).isDirectory)
    }

    func testInPlaceWritesHaveFreshModificationDatesWithCachedMembership() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wire = root.appendingPathComponent("wire.jsonl")
        try Data("start".utf8).write(to: wire)
        let cache = ActivityDirectoryCache()
        let cachedURL = try XCTUnwrap(cache.entries(at: root).first).url
        let before = try XCTUnwrap(ActivityDirectoryCache.modificationDate(at: cachedURL))
        let directoryBefore = ActivityDirectoryCache.modificationDate(at: root)
        try FileManager.default.setAttributes([.modificationDate: before + 10], ofItemAtPath: wire.path)
        XCTAssertEqual(ActivityDirectoryCache.modificationDate(at: root), directoryBefore)
        XCTAssertEqual(cache.entries(at: root).count, 1)
        XCTAssertEqual(try XCTUnwrap(ActivityDirectoryCache.modificationDate(at: cachedURL))
            .timeIntervalSince1970, (before + 10).timeIntervalSince1970, accuracy: 0.001)
    }
}
