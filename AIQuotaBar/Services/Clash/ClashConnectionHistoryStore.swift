import Foundation

final class ClashConnectionHistoryStore {
    static let shared = ClashConnectionHistoryStore()

    private static let currentSchemaVersion = 1

    private let fileManager: FileManager
    private let directoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        directoryURL = appSupport
            .appendingPathComponent(
                "com.techfanseric.aiquotabar",
                isDirectory: true)
            .appendingPathComponent("clash", isDirectory: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    init(
        directoryURL: URL,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    var fileURL: URL {
        directoryURL.appendingPathComponent(
            "openai-connection-history.json")
    }

    func load(relativeTo date: Date = Date())
        -> [ClashConnectionHistorySample]
    {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let payload = try? decoder.decode(StoreFile.self, from: data),
              payload.version <= Self.currentSchemaVersion else {
            return []
        }

        return ClashConnectionHistory.pruned(
            payload.samples,
            relativeTo: date)
    }

    func save(_ samples: [ClashConnectionHistorySample]) {
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true)
            let payload = StoreFile(
                version: Self.currentSchemaVersion,
                samples: samples)
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
#if DEBUG
            print(
                "ClashConnectionHistoryStore save failed: "
                    + error.localizedDescription)
#endif
        }
    }

    private struct StoreFile: Codable {
        let version: Int
        let samples: [ClashConnectionHistorySample]
    }
}
