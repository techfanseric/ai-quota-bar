import Foundation

/// 云端同步失败时的本地重试队列。
/// 失败的 payload 落盘到 `~/Library/Application Support/com.techfanseric.aiquotabar/sync-queue/`
/// 下次 `syncUsageData` 成功后再 flush，避免网络抖动丢一条快照。
///
/// 队列是 best-effort：磁盘失败时静默吞错，最多堆积几十 KB，无清理需求。
final class CloudSyncQueue {
    private let directoryURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        self.directoryURL = appSupport
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
    func enqueue(payload: CloudUsageSnapshotPayload) {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try encoder.encode(payload)
            let url = directoryURL.appendingPathComponent("\(UUID().uuidString).json")
            let options: Data.WritingOptions = [.atomic]
            try data.write(to: url, options: options)
        } catch {
#if DEBUG
            print("CloudSyncQueue enqueue failed: \(error.localizedDescription)")
#endif
        }
    }

    /// 遍历队列，按写入顺序逐条发送。
    /// 任何一条发送失败就保留文件，成功的删掉。`send` 闭包 throw 表示失败。
    func flush(_ send: (CloudUsageSnapshotPayload) async throws -> Void) async {
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

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let payload = try? decoder.decode(CloudUsageSnapshotPayload.self, from: data) else {
                // 解码失败的文件直接清掉，避免反复阻塞队列
                try? fileManager.removeItem(at: file)
                continue
            }

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
