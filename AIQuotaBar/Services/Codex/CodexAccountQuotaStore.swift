import Foundation

/// 单个 Codex 账号最近一次成功抓取的配额快照：
/// 短周期（5h）与长周期（Weekly）的剩余百分比与重置时间。
struct CodexAccountQuotaSnapshot: Codable, Equatable {
    let shortRemainingPercent: Int?
    let shortResetsAt: Date?
    let longRemainingPercent: Int?
    let longResetsAt: Date?
    let capturedAt: Date
}

/// 按账号指纹（CodexLocalUsageCore 的 accountDigest）持久化最近配额快照。
/// 路径：~/Library/Application Support/com.techfanseric.aiquotabar/account-quota.json
///
/// 只在抓取时账号观察稳定（前后 digest 一致）时由 CodexService 写入；
/// 切换账号后，池里账号仍可用各自的历史快照在面板上展示「上次获取到的配额」。
@MainActor
final class CodexAccountQuotaStore {
    static let shared = CodexAccountQuotaStore()

    private static let maxAccounts = 32

    private let fileURL: URL
    private let fileManager: FileManager
    private var snapshots: [String: CodexAccountQuotaSnapshot]

    init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let directoryURL {
            self.fileURL = directoryURL
                .appendingPathComponent("account-quota.json")
        } else {
            let appSupport = fileManager.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
            self.fileURL = appSupport
                .appendingPathComponent("com.techfanseric.aiquotabar", isDirectory: true)
                .appendingPathComponent("account-quota.json")
        }
        self.snapshots = [:]
        load()
    }

    func snapshot(for accountDigest: String) -> CodexAccountQuotaSnapshot? {
        snapshots[accountDigest]
    }

    /// 剩余量 = 100 - usedPercent；primary 缺失时整个快照不记。
    func record(
        accountDigest: String,
        primaryUsedPercent: Double?,
        primaryResetsAt: Date?,
        secondaryUsedPercent: Double?,
        secondaryResetsAt: Date?,
        now: Date = .now
    ) {
        guard let primaryUsedPercent else { return }
        let snapshot = CodexAccountQuotaSnapshot(
            shortRemainingPercent: Self.remainingPercent(from: primaryUsedPercent),
            shortResetsAt: primaryResetsAt,
            longRemainingPercent: secondaryUsedPercent.map(Self.remainingPercent(from:)),
            longResetsAt: secondaryResetsAt,
            capturedAt: now)
        snapshots[accountDigest] = snapshot
        prune()
        save()
    }

    private static func remainingPercent(from usedPercent: Double) -> Int {
        min(100, max(0, Int((100 - usedPercent).rounded())))
    }

    /// 只保留最近活跃的若干账号，防止文件无限增长。
    private func prune() {
        guard snapshots.count > Self.maxAccounts else { return }
        let overflow = snapshots.count - Self.maxAccounts
        let oldest = snapshots
            .sorted { $0.value.capturedAt < $1.value.capturedAt }
            .prefix(overflow)
            .map(\.key)
        for key in oldest {
            snapshots.removeValue(forKey: key)
        }
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode(
                [String: CodexAccountQuotaSnapshot].self, from: data) else { return }
        snapshots = decoded
    }

    private func save() {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(snapshots).write(to: fileURL, options: .atomic)
        } catch {
            #if DEBUG
            print("CodexAccountQuotaStore save failed: \(error.localizedDescription)")
            #endif
        }
    }
}
