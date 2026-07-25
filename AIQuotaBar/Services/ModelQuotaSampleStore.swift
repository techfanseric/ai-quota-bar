import Foundation

/// Current-window curve sample persistence, including Weekly fallback curves.
/// Path: `~/Library/Application Support/com.techfanseric.aiquotabar/samples/{provider}.json`
final class ModelQuotaSampleStore {
    static let shared = ModelQuotaSampleStore()

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
            .appendingPathComponent("samples", isDirectory: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

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

    func loadAll() -> [String: [ModelQuotaSample]] {
        var result: [String: [ModelQuotaSample]] = [:]
        for provider in UsageProvider.allCases {
            result.merge(load(for: provider), uniquingKeysWith: Self.mergedSamples)
        }
        return result
    }

    func load(for provider: UsageProvider) -> [String: [ModelQuotaSample]] {
        let url = fileURL(for: provider)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (raw["version"] as? Int ?? 0) <= Self.currentSchemaVersion,
              let payload = try? decoder.decode(StoreFile.self, from: data) else {
            return [:]
        }
        return payload.samples ?? [:]
    }

    func saveAll(_ samples: [String: [ModelQuotaSample]]) {
        for provider in UsageProvider.allCases {
            save(Self.samples(samples, for: provider), for: provider)
        }
    }

    func save(_ samples: [String: [ModelQuotaSample]], for provider: UsageProvider) {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let payload = StoreFile(version: Self.currentSchemaVersion, samples: samples)
            let data = try encoder.encode(payload)
            try data.write(to: fileURL(for: provider), options: [.atomic])
        } catch {
#if DEBUG
            print("ModelQuotaSampleStore save failed for \(provider.rawValue): \(error.localizedDescription)")
#endif
        }
    }

    func clearAll() {
        for provider in UsageProvider.allCases {
            let url = fileURL(for: provider)
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private static func samples(_ samples: [String: [ModelQuotaSample]], for provider: UsageProvider) -> [String: [ModelQuotaSample]] {
        samples.filter { modelID, _ in
            modelID == provider.rawValue || modelID.hasPrefix("\(provider.rawValue):")
        }
    }

    private static func mergedSamples(_ lhs: [ModelQuotaSample], _ rhs: [ModelQuotaSample]) -> [ModelQuotaSample] {
        var byTimestamp = Dictionary(uniqueKeysWithValues: lhs.map { ($0.id, $0) })
        for sample in rhs {
            byTimestamp[sample.id] = sample
        }
        return byTimestamp.values.sorted { $0.timestamp < $1.timestamp }
    }

    private struct StoreFile: Codable {
        let version: Int
        let samples: [String: [ModelQuotaSample]]?
    }
}
