import XCTest
@testable import AIQuotaBar

/// 覆盖 ModelUtilizationHistoryStore 的 load/save 路径:
/// - 损坏文件 (JSON 解析失败 / schema version 不匹配) → move 到 corrupt/ 备份 + 返回空
/// - 读失败 → **不应** move 文件（防止数据锁死在备份里）
/// - 正常 save/load 等幂
/// - save 失败 → 发 didFailToSaveHistory 通知
final class ModelUtilizationHistoryStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: ModelUtilizationHistoryStore!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("util-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = ModelUtilizationHistoryStore(directoryURL: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Load 路径

    func test_noFile_returnsEmptyWithoutCorruptDir() {
        let result = store.load(for: .miniMax)
        XCTAssertTrue(result.historiesOrEmpty.isEmpty, "不存在的文件应返回空 store")

        // 没有文件 → 不应触发 backup,corrupt/ 目录也不应被创建
        let corruptDir = tempDir.appendingPathComponent("corrupt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptDir.path),
                       "无文件场景下不应创建 corrupt/ 目录")
    }

    func test_corruptJSON_movesToCorruptBackup() {
        let provider = UsageProvider.glm
        let url = store.fileURL(for: provider)
        try? "{ invalid json".data(using: .utf8)?.write(to: url, options: [.atomic])

        let result = store.load(for: provider)

        XCTAssertTrue(result.historiesOrEmpty.isEmpty, "损坏 JSON 应返回空 store")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "损坏文件应被 move 到 corrupt/,原路径应不存在")
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptDirPath()),
                      "corrupt/ 目录应被创建")
    }

    func test_schemaVersionMismatch_movesToCorruptBackup() {
        let provider = UsageProvider.miniMax
        let url = store.fileURL(for: provider)
        try? #"{ "version": 999, "histories": {} }"#.data(using: .utf8)?.write(to: url, options: [.atomic])

        let result = store.load(for: provider)

        XCTAssertTrue(result.historiesOrEmpty.isEmpty, "新版本 schema 应返回空 store")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "version 不匹配文件应被 move 到 corrupt/")
    }

    func test_corruptFile_postsBackupNotification() {
        let provider = UsageProvider.codex
        let url = store.fileURL(for: provider)
        try? "not json".data(using: .utf8)?.write(to: url, options: [.atomic])

        let expectation = expectation(forNotification: ModelUtilizationHistoryStore.didBackupCorruptHistory,
                                      object: nil)

        _ = store.load(for: provider)

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Round-trip

    func test_saveLoad_roundTrip_singleModel() {
        let provider = UsageProvider.miniMax
        let history = ModelUtilizationHistory(
            modelId: "test:single",
            entries: [
                UtilizationHistoryEntry(
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    usedPercent: 50,
                    resetsAt: Date(timeIntervalSince1970: 1_700_500_000)
                )
            ]
        )
        let payload = ModelUtilizationStoreData(histories: ["test:single": history])

        store.save(payload, for: provider)
        let loaded = store.load(for: provider)

        XCTAssertEqual(loaded.historiesOrEmpty["test:single"]?.entries.count, 1)
        XCTAssertEqual(loaded.historiesOrEmpty["test:single"]?.entries.first?.usedPercent, 50)
    }

    func test_saveLoad_roundTrip_multipleModels() {
        let provider = UsageProvider.codex
        let modelA = ModelUtilizationHistory(
            modelId: "codex:a",
            entries: [
                UtilizationHistoryEntry(
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    usedPercent: 30,
                    resetsAt: Date(timeIntervalSince1970: 1_700_500_000)
                )
            ]
        )
        let modelB = ModelUtilizationHistory(
            modelId: "codex:b",
            entries: [
                UtilizationHistoryEntry(
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_100),
                    usedPercent: 70,
                    resetsAt: nil
                )
            ]
        )
        let payload = ModelUtilizationStoreData(histories: ["codex:a": modelA, "codex:b": modelB])

        store.save(payload, for: provider)
        let loaded = store.load(for: provider)

        XCTAssertEqual(loaded.historiesOrEmpty["codex:a"]?.entries.first?.usedPercent, 30)
        XCTAssertEqual(loaded.historiesOrEmpty["codex:b"]?.entries.first?.usedPercent, 70)
        XCTAssertNil(loaded.historiesOrEmpty["codex:b"]?.entries.first?.resetsAt)
    }

    // MARK: - Save failure

    func test_saveFailure_postsNotification() {
        // 构造一个 directoryURL 让 createDirectory 失败:把 directoryURL 指向一个已存在的普通文件。
        let blockingFile = tempDir.appendingPathComponent("blocking-file")
        try? "x".write(to: blockingFile, atomically: true, encoding: .utf8)

        let brokenStore = ModelUtilizationHistoryStore(directoryURL: blockingFile)
        let payload = ModelUtilizationStoreData(histories: ["k": ModelUtilizationHistory(modelId: "k")])

        let expectation = expectation(forNotification: ModelUtilizationHistoryStore.didFailToSaveHistory,
                                      object: nil)

        brokenStore.save(payload, for: .glm)

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Helpers

    private func corruptDirPath() -> String {
        tempDir.appendingPathComponent("corrupt").path
    }
}
