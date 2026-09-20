import Foundation
import CodexLocalUsageCore

/// 云端同步失败时的本地重试队列。
/// 失败的 payload 落盘到 `~/Library/Application Support/com.techfanseric.aiquotabar/sync-queue/`
/// 下次 `syncUsageData` 成功后再 flush，避免网络抖动丢一条快照。
///
/// 队列有上限（`maxQueueSize`）：网络长期挂掉时无界堆积会占满磁盘。
/// 超限时按修改时间丢最旧的文件，保留最新的若干条。
final class CloudSyncQueue {
    /// Snapshot count limit, not a time guarantee. At one batch per 10 minutes,
    /// 50 entries cover about 8 hours; local usage events use a separate durable outbox.
    static let maxQueueSize = 50

    private let directoryURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        self.fileManager = fileManager
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        self.directoryURL = directoryURL ?? appSupport
            .appendingPathComponent("com.techfanseric.aiquotabar", isDirectory: true)
            .appendingPathComponent("sync-queue", isDirectory: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// 把 payload 写到队列目录。每个文件用 UUID 命名避免重名。
    /// 入队前先 trim 超限文件（按修改时间丢最旧的）。
    func enqueue(payload: CloudUsageSnapshotPayload) {
        guard let binding = payload.teamBinding else { return }
        let directoryURL = scopedDirectory(binding)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            trimIfNeeded(in: directoryURL)
            let data = try encoder.encode(payload.teamSnapshot)
            let url = directoryURL.appendingPathComponent("\(UUID().uuidString).json")
            let options: Data.WritingOptions = [.atomic]
            try data.write(to: url, options: options)
        } catch {
#if DEBUG
            print("CloudSyncQueue enqueue failed: \(error.localizedDescription)")
#endif
        }
    }

    struct Statistics {
        var bytes: Int64 = 0
        var currentTeamFiles = 0
        var otherFiles = 0
    }
    func statistics(binding: String?) -> Statistics {
        var result = Statistics()
        let current = binding.map(scopedDirectory)
        if let enumerator = fileManager.enumerator(at: directoryURL, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
            for case let file as URL in enumerator where file.pathExtension == "json" {
                result.bytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                if file.deletingLastPathComponent().standardizedFileURL.path == current?.standardizedFileURL.path { result.currentTeamFiles += 1 }
                else { result.otherFiles += 1 }
            }
        }
        return result
    }

    func clearAll() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for file in files {
            try? fileManager.removeItem(at: file)
        }
    }

    /// 按修改时间排序，删到 `maxQueueSize` 以下。
    private func trimIfNeeded(in directoryURL: URL) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let jsonFiles = files.filter { $0.pathExtension == "json" }
        guard jsonFiles.count >= Self.maxQueueSize else { return }

        // 按修改时间升序排，最旧的在前面
        let sorted = jsonFiles.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate < rhsDate
        }

        let toRemove = sorted.count - Self.maxQueueSize + 1  // +1 给即将写入的新文件留位
        for file in sorted.prefix(max(toRemove, 0)) {
            try? fileManager.removeItem(at: file)
        }
    }

    /// 遍历队列，按写入顺序逐条发送。
    /// 任何一条发送失败就保留文件，成功的删掉。`send` 闭包 throw 表示失败。
    private func scopedDirectory(_ binding: String) -> URL { directoryURL.appendingPathComponent(usageDigest(binding), isDirectory: true) }

    func flush(binding: String, _ send: (CloudUsageSnapshotPayload) async throws -> Void) async {
        let directoryURL = scopedDirectory(binding)
        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return
        }

        let ordered = files.filter { $0.pathExtension == "json" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        for file in ordered {
            guard let data = try? Data(contentsOf: file),
                  let payload = try? decoder.decode(CloudUsageSnapshotPayload.self, from: data) else {
                // 解码失败的文件直接清掉，避免反复阻塞队列
                try? fileManager.removeItem(at: file)
                continue
            }

            // Unscoped legacy payloads are quarantined, never adopted by a new team.
            guard payload.teamBinding == binding else { continue }
            do {
                try await send(payload)
                try? fileManager.removeItem(at: file)
            } catch {
                // 这条失败就停下，剩下的也别试了（多半是同一个原因）
                return
            }
        }
    }
}

/// 同步状态枚举：UI 可读 `lastSyncStatus` 显示 "Last sync: 2m ago" 或失败原因
enum CloudSyncStatus {
    case idle
    case success(at: Date)
    case failure(at: Date, reason: CloudSyncFailureReason, error: Error?)

    var lastSuccessDate: Date? {
        if case .success(let date) = self { return date }
        return nil
    }

    var lastFailureDate: Date? {
        if case .failure(let date, _, _) = self { return date }
        return nil
    }
}

enum CloudSyncFailureReason: String {
    case missingToken
    case invalidEndpoint
    case encodingFailed
    case network
}

/// 单个 model 的 utilization 历史 payload（云端序列化形态）
struct CloudUtilizationHistoryPayload: Codable {
    let modelId: String
    let entries: [CloudUtilizationEntryPayload]

    init(history: ModelUtilizationHistory) {
        self.modelId = history.modelId
        self.entries = history.entries.map { CloudUtilizationEntryPayload(entry: $0) }
    }
}

struct CloudUtilizationEntryPayload: Codable {
    let capturedAt: Date
    let usedPercent: Double
    let resetsAt: Date?

    init(entry: UtilizationHistoryEntry) {
        self.capturedAt = entry.capturedAt
        self.usedPercent = entry.usedPercent
        self.resetsAt = entry.resetsAt
    }
}
