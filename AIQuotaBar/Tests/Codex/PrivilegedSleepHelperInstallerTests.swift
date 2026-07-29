import CryptoKit
import Foundation
import XCTest
@testable import AIQuotaBar

final class PrivilegedSleepHelperInstallerTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var bundledHelperURL: URL!
    private var bundledPlistURL: URL!
    private var appExecutableURL: URL!
    private var installedHelperURL: URL!
    private var installedPlistURL: URL!
    private var markerURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true)

        bundledHelperURL = temporaryDirectory
            .appendingPathComponent("bundled-helper")
        bundledPlistURL = temporaryDirectory
            .appendingPathComponent("legacy.plist")
        appExecutableURL = temporaryDirectory
            .appendingPathComponent("AIQuotaBar")
        installedHelperURL = temporaryDirectory
            .appendingPathComponent("installed-helper")
        installedPlistURL = temporaryDirectory
            .appendingPathComponent("installed.plist")
        markerURL = temporaryDirectory
            .appendingPathComponent("authorized-client")

        try Data("helper-v1".utf8).write(
            to: bundledHelperURL)
        try Data("plist".utf8).write(
            to: bundledPlistURL)
        try Data("app-v1".utf8).write(
            to: appExecutableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: bundledHelperURL.path)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(
                at: temporaryDirectory)
        }
        try super.tearDownWithError()
    }

    func testReportsInstalledOnlyForMatchingPayloadAndClient() throws {
        let installer = makeInstaller()
        XCTAssertEqual(
            installer.installationStatus(),
            .missing)

        try FileManager.default.copyItem(
            at: bundledHelperURL,
            to: installedHelperURL)
        try FileManager.default.copyItem(
            at: bundledPlistURL,
            to: installedPlistURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: installedHelperURL.path)
        try """
        \(appExecutableURL.path)
        \(digest(appExecutableURL))
        """.write(
            to: markerURL,
            atomically: true,
            encoding: .utf8)

        XCTAssertEqual(
            installer.installationStatus(),
            .installed)
    }

    func testDetectsChangedHelperOrAppAsOutdated() throws {
        let installer = makeInstaller()
        try FileManager.default.copyItem(
            at: bundledHelperURL,
            to: installedHelperURL)
        try FileManager.default.copyItem(
            at: bundledPlistURL,
            to: installedPlistURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: installedHelperURL.path)
        try """
        \(appExecutableURL.path)
        \(digest(appExecutableURL))
        """.write(
            to: markerURL,
            atomically: true,
            encoding: .utf8)

        try Data("helper-v2".utf8).write(
            to: installedHelperURL)
        XCTAssertEqual(
            installer.installationStatus(),
            .outdated)

        try Data(contentsOf: bundledHelperURL).write(
            to: installedHelperURL)
        try Data("app-v2".utf8).write(
            to: appExecutableURL)
        XCTAssertEqual(
            installer.installationStatus(),
            .outdated)
    }

    private func makeInstaller()
        -> PrivilegedSleepHelperInstaller
    {
        PrivilegedSleepHelperInstaller(
            bundledHelperURL: bundledHelperURL,
            legacyPlistURL: bundledPlistURL,
            appExecutableURL: appExecutableURL,
            installedHelperURL: installedHelperURL,
            installedPlistURL: installedPlistURL,
            authorizedClientMarkerURL: markerURL)
    }

    private func digest(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
