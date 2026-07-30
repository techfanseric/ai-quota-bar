import AppKit
import SwiftUI
import XCTest
@testable import AIQuotaBar

final class ClashConnectionTests: XCTestCase {
    func testConnectionDetailStartsWithNetworkAndOmitsProcess() {
        XCTAssertEqual(
            ClashConnectionFormat.detail(
                network: "tcp",
                chain: "Japan 01"),
            "TCP · Japan 01")
        XCTAssertEqual(
            ClashConnectionFormat.detail(
                network: " udp ",
                chain: nil),
            "UDP")
        XCTAssertEqual(
            ClashConnectionFormat.detail(
                network: nil,
                chain: "Singapore 02"),
            "Singapore 02")
        XCTAssertNil(
            ClashConnectionFormat.detail(
                network: " ",
                chain: nil))
    }

    @MainActor
    func testLiveClashConnectionViewRendersWhenExplicitlyEnabled()
        async throws
    {
        guard ProcessInfo.processInfo.environment[
            "AIQUOTABAR_LIVE_CLASH_TEST"] == "1" else {
            throw XCTSkip("Set AIQUOTABAR_LIVE_CLASH_TEST=1 to run.")
        }

        let defaultsSuiteName =
            "ClashConnectionLiveRender.\(UUID())"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: defaultsSuiteName))
        defer {
            defaults.removePersistentDomain(
                forName: defaultsSuiteName)
        }

        let historyStore = ClashRouteSwitchHistoryStore(
            defaults: defaults)
        let now = Date()
        historyStore.recordSwitch(
            from: "🇺🇸 US Los Angeles 01",
            to: "🇯🇵 Japan Tokyo 03",
            at: now.addingTimeInterval(-1_800))
        historyStore.recordSwitch(
            from: "🇯🇵 Japan Tokyo 03",
            to: "🇸🇬 Singapore 07",
            at: now.addingTimeInterval(-900))
        historyStore.recordSwitch(
            from: "🇸🇬 Singapore 07",
            to: "🇯🇵 Japan Tokyo 01",
            at: now.addingTimeInterval(-120))

        let routeViewModel = ClashRouteViewModel(
            defaults: defaults)
        let connectionViewModel = ClashConnectionViewModel()
        let sleepProtectionCoordinator = CodexSleepProtectionCoordinator(
            localActivityProvider: nil
        )
        connectionViewModel.beginLiveUpdates()
        await routeViewModel.prepareForDisplay(
            automaticallyTest: false)
        try await Task.sleep(for: .seconds(3))
        defer {
            connectionViewModel.stop()
        }

        guard case .ready = connectionViewModel.phase else {
            XCTFail("Live Clash connection view did not become ready.")
            return
        }
        guard case .ready = routeViewModel.phase else {
            XCTFail("Clash route view did not become ready.")
            return
        }

        let size = NSSize(
            width: ClashPopoverLayout.width,
            height: ClashPopoverLayout.height)
        let hostingView = NSHostingView(
            rootView: ClashPopoverView(
                routeViewModel: routeViewModel,
                connectionViewModel: connectionViewModel,
                sleepProtectionCoordinator: sleepProtectionCoordinator)
                .frame(width: size.width, height: size.height))
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(
            in: hostingView.bounds) else {
            XCTFail("Could not create a view bitmap.")
            return
        }
        hostingView.cacheDisplay(
            in: hostingView.bounds,
            to: bitmap)
        guard let png = bitmap.representation(
            using: .png,
            properties: [:]) else {
            XCTFail("Could not encode the view bitmap.")
            return
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "aiquotabar-openai-connections.png")
        try png.write(to: outputURL, options: [.atomic])
        XCTAssertGreaterThan(png.count, 10_000)
    }

    func testLiveClashConnectionStreamWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment[
            "AIQUOTABAR_LIVE_CLASH_TEST"] == "1" else {
            throw XCTSkip("Set AIQUOTABAR_LIVE_CLASH_TEST=1 to run.")
        }

        let configuration = try ClashConfigurationDiscovery().discover()
        let client = ClashAPIClient(configuration: configuration)
        _ = try await client.version()

        let observations = try await withThrowingTaskGroup(
            of: [(Date, ClashConnectionsResponse)].self
        ) { group in
            group.addTask {
                var observations: [(Date, ClashConnectionsResponse)] = []
                for try await response in client.connectionSnapshots(
                    intervalMilliseconds: 1_000) {
                    observations.append((Date(), response))
                    if observations.count == 3 {
                        return observations
                    }
                }
                throw ClashIntegrationError.controllerUnavailable
            }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw ClashIntegrationError.controllerUnavailable
            }

            guard let first = try await group.next() else {
                throw ClashIntegrationError.controllerUnavailable
            }
            group.cancelAll()
            return first
        }

        XCTAssertFalse(
            observations.last?.1.connections.isEmpty ?? true)
        XCTAssertGreaterThanOrEqual(
            observations[2].0.timeIntervalSince(observations[0].0),
            1.5)
    }

    func testConnectionsResponseDecodesMihomoFields() throws {
        let json = """
        {
          "downloadTotal": 1234,
          "uploadTotal": 567,
          "memory": 999,
          "connections": [
            {
              "id": "connection-1",
              "download": 400,
              "upload": 100,
              "chains": ["AI group", "JP 01"],
              "rule": "DomainSuffix",
              "rulePayload": "openai.com",
              "start": "2026-07-29T07:00:00.123456Z",
              "metadata": {
                "network": "tcp",
                "type": "HTTP",
                "destinationIP": "203.0.113.1",
                "host": "api.openai.com",
                "process": "Codex",
                "processPath": "/Applications/Codex.app",
                "remoteDestination": "api.openai.com:443",
                "sniffHost": ""
              }
            }
          ]
        }
        """

        let response = try JSONDecoder().decode(
            ClashConnectionsResponse.self,
            from: Data(json.utf8))

        XCTAssertEqual(response.downloadTotal, 1_234)
        XCTAssertEqual(response.uploadTotal, 567)
        XCTAssertEqual(response.connections.count, 1)
        XCTAssertEqual(
            response.connections.first?.metadata.host,
            "api.openai.com")
        XCTAssertNotNil(
            ClashConnectionDateParser.date(
                from: response.connections[0].start))
    }

    func testFilterMatchesOnlyOpenAIAndChatGPTDomainSuffixes() {
        for host in [
            "openai.com",
            "api.openai.com",
            "chatgpt.com:443",
            "https://ab.chatgpt.com/path",
        ] {
            XCTAssertTrue(
                ClashOpenAIConnectionFilter.matches(
                    record(id: host, host: host)),
                host)
        }

        for host in [
            "notopenai.example",
            "openai.example.com",
            "oaistatic.com",
            "chatgpt.example",
        ] {
            XCTAssertFalse(
                ClashOpenAIConnectionFilter.matches(
                    record(id: host, host: host)),
                host)
        }
    }

    func testFilterUsesSniffHostAndRulePayloadFallbacks() {
        XCTAssertTrue(
            ClashOpenAIConnectionFilter.matches(
                record(
                    id: "sniffed",
                    host: nil,
                    sniffHost: "ios.chatgpt.com")))
        XCTAssertTrue(
            ClashOpenAIConnectionFilter.matches(
                record(
                    id: "rule",
                    host: nil,
                    rulePayload: "+.openai.com")))
    }

    func testActivityCalculatorComputesFilteredPerSecondRates() {
        let start = Date(timeIntervalSince1970: 1_785_307_190)
        var calculator = ClashConnectionActivityCalculator()

        let first = calculator.update(
            response: response([
                record(
                    id: "openai",
                    host: "api.openai.com",
                    upload: 1_000,
                    download: 2_000,
                    start: start.addingTimeInterval(-10)),
                record(
                    id: "other",
                    host: "example.com",
                    upload: 9_000,
                    download: 9_000,
                    start: start),
            ]),
            observedAt: start)

        XCTAssertEqual(first.connections.map(\.id), ["openai"])
        XCTAssertEqual(first.uploadSpeed, 0)
        XCTAssertEqual(first.downloadSpeed, 0)

        let second = calculator.update(
            response: response([
                record(
                    id: "openai",
                    host: "api.openai.com",
                    upload: 1_600,
                    download: 3_000,
                    start: start.addingTimeInterval(-10)),
            ]),
            observedAt: start.addingTimeInterval(2))

        XCTAssertEqual(second.uploadSpeed, 300, accuracy: 0.001)
        XCTAssertEqual(second.downloadSpeed, 500, accuracy: 0.001)
        XCTAssertEqual(
            second.connections.first?.duration ?? 0,
            12,
            accuracy: 0.001)
    }

    func testNewAndResetConnectionsDoNotCreateSpeedSpikes() {
        let start = Date(timeIntervalSince1970: 1_785_307_200)
        var calculator = ClashConnectionActivityCalculator()

        _ = calculator.update(
            response: response([
                record(
                    id: "one",
                    host: "chatgpt.com",
                    upload: 5_000,
                    download: 7_000,
                    start: start),
            ]),
            observedAt: start)

        let reset = calculator.update(
            response: response([
                record(
                    id: "one",
                    host: "chatgpt.com",
                    upload: 10,
                    download: 20,
                    start: start),
                record(
                    id: "new",
                    host: "api.openai.com",
                    upload: 2_000,
                    download: 3_000,
                    start: start),
            ]),
            observedAt: start.addingTimeInterval(1))

        XCTAssertEqual(reset.uploadSpeed, 0)
        XCTAssertEqual(reset.downloadSpeed, 0)
    }

    func testHistoryReplacesCurrentMinuteAndKeepsSixtySamples() {
        let currentMinute = Date(timeIntervalSince1970: 1_785_307_200)
        var samples = (1 ... 65).map { offset in
            ClashConnectionHistorySample(
                timestamp: currentMinute.addingTimeInterval(
                    -Double(offset) * 60),
                connectionAges: [Double(offset)])
        }

        let snapshot = ClashConnectionActivitySnapshot(
            observedAt: currentMinute.addingTimeInterval(35),
            connections: [
                activeConnection(id: "new", duration: 10),
                activeConnection(id: "old", duration: 4_000),
            ],
            uploadSpeed: 0,
            downloadSpeed: 0)
        samples = ClashConnectionHistory.upserting(
            snapshot: snapshot,
            into: samples)

        XCTAssertEqual(samples.count, 60)
        XCTAssertEqual(samples.last?.timestamp, currentMinute)
        XCTAssertEqual(samples.last?.connectionAges, [4_000, 10])

        let replacement = ClashConnectionActivitySnapshot(
            observedAt: currentMinute.addingTimeInterval(55),
            connections: [
                activeConnection(id: "only", duration: 30),
            ],
            uploadSpeed: 0,
            downloadSpeed: 0)
        samples = ClashConnectionHistory.upserting(
            snapshot: replacement,
            into: samples)

        XCTAssertEqual(samples.count, 60)
        XCTAssertEqual(samples.last?.connectionAges, [30])
    }

    func testHistoryStoreRoundTripsAggregateAgesOnly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "clash-connections-\(UUID().uuidString)",
                isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let store = ClashConnectionHistoryStore(
            directoryURL: directory)
        let date = ClashConnectionHistory.minuteStart(
            for: Date())
        let samples = [
            ClashConnectionHistorySample(
                timestamp: date,
                connectionAges: [5, 70]),
        ]

        store.save(samples)
        XCTAssertEqual(
            store.load(relativeTo: date),
            samples)

        let persistedText = try String(
            contentsOf: store.fileURL,
            encoding: .utf8)
        XCTAssertFalse(persistedText.contains("openai.com"))
        XCTAssertFalse(persistedText.contains("process"))
        XCTAssertFalse(persistedText.contains("destinationIP"))
    }

    func testAgeScaleClampsAtOneHour() {
        XCTAssertEqual(
            ClashConnectionAgeScale.progress(for: -1),
            0)
        XCTAssertEqual(
            ClashConnectionAgeScale.progress(for: 30 * 60),
            0.5,
            accuracy: 0.001)
        XCTAssertEqual(
            ClashConnectionAgeScale.progress(for: 2 * 60 * 60),
            1)
    }

    private func response(
        _ connections: [ClashConnectionRecord]
    ) -> ClashConnectionsResponse {
        ClashConnectionsResponse(
            downloadTotal: nil,
            uploadTotal: nil,
            connections: connections)
    }

    private func record(
        id: String,
        host: String?,
        sniffHost: String? = nil,
        rulePayload: String? = nil,
        upload: Int64 = 0,
        download: Int64 = 0,
        start: Date = Date(timeIntervalSince1970: 1_785_307_200)
    ) -> ClashConnectionRecord {
        ClashConnectionRecord(
            id: id,
            download: download,
            upload: upload,
            chains: ["AI group", "JP 01"],
            rule: "DomainSuffix",
            rulePayload: rulePayload,
            start: ISO8601DateFormatter().string(from: start),
            metadata: ClashConnectionMetadata(
                network: "tcp",
                type: "HTTP",
                destinationIP: "203.0.113.1",
                host: host,
                process: "Codex",
                processPath: nil,
                remoteDestination: nil,
                sniffHost: sniffHost))
    }

    private func activeConnection(
        id: String,
        duration: TimeInterval
    ) -> ClashActiveConnection {
        ClashActiveConnection(
            id: id,
            host: "api.openai.com",
            process: "Codex",
            network: "tcp",
            chains: ["AI group"],
            startedAt: nil,
            duration: duration,
            uploadSpeed: 0,
            downloadSpeed: 0)
    }
}
