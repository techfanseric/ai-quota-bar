import Foundation
import XCTest
@testable import AIQuotaBar

final class ClashConfigurationDiscoveryTests: XCTestCase {
    func testTopLevelYAMLReadsControllerAndQuotedSecretWithoutNestedKeys() {
        let values = ClashTopLevelYAML.parse(
            """
            external-controller: "127.0.0.1:9097"
            secret: 'value # with comment'
            dns:
              secret: nested-value
            mode: rule # active mode
            """)

        XCTAssertEqual(values["external-controller"], "127.0.0.1:9097")
        XCTAssertEqual(values["secret"], "value # with comment")
        XCTAssertEqual(values["mode"], "rule")
    }

    func testControllerURLNormalizesWildcardBindingToLoopback() throws {
        let url = try ClashConfigurationDiscovery.controllerURL(
            from: "0.0.0.0:9097")

        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:9097")
    }

    func testControllerURLRejectsRemoteHosts() {
        XCTAssertThrowsError(
            try ClashConfigurationDiscovery.controllerURL(
                from: "192.168.1.2:9097")) { error in
            XCTAssertEqual(
                error as? ClashIntegrationError,
                .unsafeControllerHost("192.168.1.2"))
        }
    }

    func testDiscoversClashVergeRuntimeConfiguration() throws {
        let temporaryHome = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        let configDirectory = temporaryHome.appending(
            path: "Library/Application Support/io.github.clash-verge-rev.clash-verge-rev")
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryHome)
        }

        let configURL = configDirectory.appending(path: "clash-verge.yaml")
        try """
        external-controller: 127.0.0.1:9097
        secret: "test-secret"
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let discovery = ClashConfigurationDiscovery(
            homeDirectory: temporaryHome)
        let configuration = try discovery.discover()

        XCTAssertEqual(
            configuration.baseURL.absoluteString,
            "http://127.0.0.1:9097")
        XCTAssertEqual(configuration.secret, "test-secret")
        XCTAssertEqual(configuration.clientName, "Clash Verge Rev")
    }
}
