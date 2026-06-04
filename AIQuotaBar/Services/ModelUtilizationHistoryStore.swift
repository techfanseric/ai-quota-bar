import Foundation

/// 跨周期 utilization 历史持久化。
/// 路径: `~/Library/Application Support/com.techfanseric.aiquotabar/history/{provider}.json`
/// 加载/保存 Best-effort：任何 IO 错误或 schema 不匹配都静默丢弃（下次 record 时自然覆盖）。
final class ModelUtilizationHistoryStore {
    static let shared = ModelUtilizationHistoryStore()

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

    func fileURL(for provider: UsageProvider) -> URL {
        directoryURL.appendingPathComponent("\(provider.rawValue).json")
    }

    func load(for provider: UsageProvider) -> ModelUtilizationStoreData {
        let url = fileURL(for: provider)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return ModelUtilizationStoreData()
        }
        let payload = try? decoder.decode(StoreFile.self, from: data)
        return ModelUtilizationStoreData(histories: payload?.histories ?? [:])
    }

    func save(_ store: ModelUtilizationStoreData, for provider: UsageProvider) {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let payload = StoreFile(version: 1, histories: store.histories)
            let data = try encoder.encode(payload)
            try data.write(to: fileURL(for: provider), options: [.atomic])
        } catch {
#if DEBUG
            print("ModelUtilizationHistoryStore save failed: \(error.localizedDescription)")
#endif
        }
    }

    private struct StoreFile: Codable {
        let version: Int
        let histories: [String: ModelUtilizationHistory]
    }
}
