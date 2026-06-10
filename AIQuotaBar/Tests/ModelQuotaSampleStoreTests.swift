import XCTest
@testable import AIQuotaBar

final class ModelQuotaSampleStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: ModelQuotaSampleStore!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quota-samples-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = ModelQuotaSampleStore(directoryURL: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func test_saveLoad_roundTrip() {
        let samples = [
            "codex:user@example.com:Codex Spark 5-hour": [
                ModelQuotaSample(
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                    remaining: 72,
                    percent: 72
                ),
                ModelQuotaSample(
                    timestamp: Date(timeIntervalSince1970: 1_700_000_060),
                    remaining: 70,
                    percent: 70
                ),
            ],
        ]

        store.save(samples, for: .codex)
        let loaded = store.load(for: .codex)

        XCTAssertEqual(loaded["codex:user@example.com:Codex Spark 5-hour"]?.count, 2)
        XCTAssertEqual(loaded["codex:user@example.com:Codex Spark 5-hour"]?.last?.remaining, 70)
        XCTAssertEqual(loaded["codex:user@example.com:Codex Spark 5-hour"]?.last?.percent, 70)
    }

    func test_saveAll_splitsByProvider() {
        let samples = [
            "codex:user@example.com:Codex Spark 5-hour": [
                ModelQuotaSample(timestamp: Date(timeIntervalSince1970: 1), remaining: 80, percent: 80),
            ],
            "minimax:MiniMax": [
                ModelQuotaSample(timestamp: Date(timeIntervalSince1970: 2), remaining: 5),
            ],
        ]

        store.saveAll(samples)

        XCTAssertEqual(store.load(for: .codex).keys.sorted(), ["codex:user@example.com:Codex Spark 5-hour"])
        XCTAssertEqual(store.load(for: .miniMax).keys.sorted(), ["minimax:MiniMax"])
        XCTAssertTrue(store.load(for: .glm).isEmpty)
    }

    func test_clearAll_removesPersistedSamples() {
        store.save([
            "codex:user@example.com:Codex Spark 5-hour": [
                ModelQuotaSample(timestamp: Date(timeIntervalSince1970: 1), remaining: 80, percent: 80),
            ],
        ], for: .codex)

        store.clearAll()

        XCTAssertTrue(store.loadAll().isEmpty)
    }
}
