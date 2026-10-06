import Foundation
import XCTest

@testable import AIQuotaBar

final class InstallerCleanupTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InstallerCleanupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeRecord(containing paths: [String], writtenAt: Date = Date()) throws -> String {
        let record = directory.appendingPathComponent("pending")
        try InstallerCleanup.encodeRecord(paths: paths, writtenAt: writtenAt)
            .write(to: record, atomically: true, encoding: .utf8)
        return record.path
    }

    func testRemovesRecordedInstallerAndTheRecordItself() throws {
        let installer = directory.appendingPathComponent("AIQuotaBar.pkg")
        try Data("payload".utf8).write(to: installer)
        let record = try makeRecord(containing: [installer.path])

        let removed = InstallerCleanup.performPendingRemoval(recordPath: record)

        XCTAssertEqual(removed, [installer.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record))
    }

    func testNeverRemovesAnythingButOurOwnInstallerName() throws {
        let bystander = directory.appendingPathComponent("SomeOtherApp.pkg")
        let notes = directory.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: bystander)
        try Data("x".utf8).write(to: notes)
        let record = try makeRecord(containing: [bystander.path, notes.path])

        XCTAssertTrue(InstallerCleanup.performPendingRemoval(recordPath: record).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bystander.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: notes.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record))
    }

    func testStaleRecordIsDroppedWithoutDeletingAnything() throws {
        let installer = directory.appendingPathComponent("AIQuotaBar.pkg")
        try Data("payload".utf8).write(to: installer)
        let record = try makeRecord(
            containing: [installer.path],
            writtenAt: Date().addingTimeInterval(-InstallerCleanup.recordMaxAge - 60))

        XCTAssertTrue(InstallerCleanup.performPendingRemoval(recordPath: record).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record))
    }

    func testMissingRecordIsNotAnError() {
        let missing = directory.appendingPathComponent("does-not-exist").path
        XCTAssertTrue(InstallerCleanup.performPendingRemoval(recordPath: missing).isEmpty)
    }

    func testRecordRoundTripKeepsPathsThatContainSpaces() throws {
        let encoded = InstallerCleanup.encodeRecord(
            paths: ["/tmp/aqb space/Downloads/AIQuotaBar.pkg"], writtenAt: Date())
        let decoded = InstallerCleanup.decodeRecord(encoded)
        XCTAssertEqual(decoded?.paths, ["/tmp/aqb space/Downloads/AIQuotaBar.pkg"])
        XCTAssertNotNil(decoded?.writtenAt)
    }

    func testMalformedRecordIsIgnored() {
        XCTAssertNil(InstallerCleanup.decodeRecord(""))
        XCTAssertNil(InstallerCleanup.decodeRecord("not-a-timestamp\n/tmp/AIQuotaBar.pkg"))
    }
}