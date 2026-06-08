import Foundation

/// 跨周期 utilization 历史持久化。
/// 路径: `~/Library/Application Support/com.techfanseric.aiquotabar/history/{provider}.json`
///
/// 加载/保存 Best-effort 策略：
/// - 加载失败（JSON 损坏 / schema 版本不匹配）→ 把原文件 rename 成 `.corrupt-{timestamp}.json` 备份到同目录，
///   返回空 store 并发出 `didBackupCorruptHistory` 通知。备份保证下次 save 不会覆盖原始数据。
/// - 保存失败（磁盘满 / 权限变更 / 目录被删）→ 发出 `didFailToSaveHistory` 通知，
///   调用方应考虑降级提示（不阻塞主刷新流程）。
final class ModelUtilizationHistoryStore {
    static let shared = ModelUtilizationHistoryStore()

    static let corruptBackupDirectoryName = "corrupt"
    static let didBackupCorruptHistory = Notification.Name("ModelUtilizationHistoryStore.didBackupCorruptHistory")
    static let didFailToSaveHistory = Notification.Name("ModelUtilizationHistoryStore.didFailToSaveHistory")
    static let corruptBackupURLUserInfoKey = "backupURL"
    static let saveFailureErrorUserInfoKey = "error"

    /// 当前 schema 版本。新增字段时递增 `currentSchemaVersion` 并实现迁移分支。
    private static let currentSchemaVersion = 1

    private let fileManager: FileManager
    private let directoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        self.directoryURL = appSupport
            .appendingPathComponent("com.techfanseric.aiquotabar", isDirectory: true)
            .appendingPathComponent("history", isDirectory: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// 测试专用 init：注入临时目录，避免污染真实 Application Support 路径。
    /// production 仍走 `static let shared` + private init。
    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func fileURL(for provider: UsageProvider) -> URL {
        directoryURL.appendingPathComponent("\(provider.rawValue).json")
    }

    /// 加载并返回 store。失败时返回空 store + 触发备份通知。
    func load(for provider: UsageProvider) -> ModelUtilizationStoreData {
        let url = fileURL(for: provider)
        guard fileManager.fileExists(atPath: url.path) else {
            return ModelUtilizationStoreData()
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // 读失败（权限/文件被占用/磁盘挂载异常）≠ 文件损坏。
            // 这种情况 move 到 corrupt/ 是过度反应——下次 load 还有机会读到，
            // 而 move 之后 save 会用空 store 覆盖原路径，把数据锁死在用户看不到的备份里。
            // 这里只 log 一下 + 返回空，不动文件。
#if DEBUG
            print("ModelUtilizationHistoryStore: read failed for \(provider.rawValue), keeping file intact: \(error.localizedDescription)")
#endif
            return ModelUtilizationStoreData()
        }

        // 解析 / 版本不匹配 / 强类型 decode 失败才视为"内容不可用"，move 到 corrupt/ 保留现场。
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            backupCorruptFile(at: url, reason: "JSON parse failed")
            return ModelUtilizationStoreData()
        }

        let fileVersion = raw["version"] as? Int ?? 0
        guard fileVersion <= Self.currentSchemaVersion else {
            backupCorruptFile(at: url, reason: "schema version \(fileVersion) newer than supported \(Self.currentSchemaVersion)")
            return ModelUtilizationStoreData()
        }

        do {
            let payload = try decoder.decode(StoreFile.self, from: data)
            return ModelUtilizationStoreData(histories: payload.histories ?? [:])
        } catch {
            backupCorruptFile(at: url, reason: "decode failed: \(error.localizedDescription)")
            return ModelUtilizationStoreData()
        }
    }

    func save(_ store: ModelUtilizationStoreData, for provider: UsageProvider) {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let payload = StoreFile(version: Self.currentSchemaVersion, histories: store.histories)
            let data = try encoder.encode(payload)
            try data.write(to: fileURL(for: provider), options: [.atomic])
        } catch {
            postSaveFailure(error: error, provider: provider)
        }
    }

    func clear(for provider: UsageProvider) {
        let url = fileURL(for: provider)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    func clearAll() {
        for provider in UsageProvider.allCases {
            clear(for: provider)
        }
    }

    private func backupCorruptFile(at url: URL, reason: String) {
        guard let backupDir = ensureCorruptBackupDirectory() else { return }
        let timestamp = Int(Date().timeIntervalSince1970)
        let backupURL = backupDir.appendingPathComponent("\(url.lastPathComponent).corrupt-\(timestamp)")
        do {
            try fileManager.moveItem(at: url, to: backupURL)
#if DEBUG
            print("ModelUtilizationHistoryStore: backed up corrupt file to \(backupURL.path) — \(reason)")
#endif
            NotificationCenter.default.post(
                name: Self.didBackupCorruptHistory,
                object: nil,
                userInfo: [Self.corruptBackupURLUserInfoKey: backupURL]
            )
        } catch {
#if DEBUG
            print("ModelUtilizationHistoryStore: failed to backup corrupt file: \(error.localizedDescription)")
#endif
        }
    }

    private func ensureCorruptBackupDirectory() -> URL? {
        let backupDir = directoryURL.appendingPathComponent(Self.corruptBackupDirectoryName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)
            return backupDir
        } catch {
#if DEBUG
            print("ModelUtilizationHistoryStore: failed to create corrupt backup dir: \(error.localizedDescription)")
#endif
            return nil
        }
    }

    private func postSaveFailure(error: Error, provider: UsageProvider) {
#if DEBUG
        print("ModelUtilizationHistoryStore save failed for \(provider.rawValue): \(error.localizedDescription)")
#endif
        NotificationCenter.default.post(
            name: Self.didFailToSaveHistory,
            object: nil,
            userInfo: [
                Self.saveFailureErrorUserInfoKey: error,
                "provider": provider.rawValue
            ]
        )
    }

    private struct StoreFile: Codable {
        let version: Int
        let histories: [String: ModelUtilizationHistory]?
    }
}
