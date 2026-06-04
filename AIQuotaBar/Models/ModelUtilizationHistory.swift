import Foundation

/// 单个 model 的一条 utilization 历史样本。
struct UtilizationHistoryEntry: Codable, Equatable {
    /// 采样时间
    let capturedAt: Date
    /// 0-100, 已用百分比（clamp）
    let usedPercent: Double
    /// 该样本归属的周期 reset 边界（即 `model.endTime` 在采样时刻的值）
    let resetsAt: Date?
}

/// 单个 model 的全部 utilization 历史（以 `modelId` 唯一）。
/// `entries` append-only，采集时按 `resetsAt` groupBy 即可得出每个完整周期的 peak。
struct ModelUtilizationHistory: Codable, Equatable {
    /// 单个 model 历史样本上限：1000 条 × 1h 节流 ≈ 41 天。
    /// 超出按 `capturedAt` 升序丢最旧的（同步调用方在 `append` 后应调 `trimToLimit()`）。
    static let maxEntriesPerModel = 1000

    let modelId: String
    var entries: [UtilizationHistoryEntry] = []

    init(modelId: String, entries: [UtilizationHistoryEntry] = []) {
        self.modelId = modelId
        self.entries = entries
    }

    /// append 一条 entry 后裁剪到上限内。返回 `true` 表示实际有裁剪。
    @discardableResult
    mutating func append(_ entry: UtilizationHistoryEntry) -> Bool {
        entries.append(entry)
        return trimToLimit()
    }

    /// 裁剪到 `maxEntriesPerModel` 内：按 `capturedAt` 升序丢最旧的。
    @discardableResult
    mutating func trimToLimit() -> Bool {
        guard entries.count > Self.maxEntriesPerModel else { return false }
        let overflow = entries.count - Self.maxEntriesPerModel
        entries.sort { $0.capturedAt < $1.capturedAt }
        entries.removeFirst(overflow)
        return true
    }

    /// 按 `resetsAt` 分组取 peak，返回按时间倒序的最近 `limit` 个周期。
    /// - `includeCurrent`（默认）：所有 resetsAt 参与计算，in-progress 周期也会出现（最右一根）
    /// - `completedOnly`：仅 `resetsAt <= now` 参与计算
    /// - 同周期多个样本取 `max(usedPercent)`（in-progress 周期取周期内历史 peak）
    /// - 入参 `now` 仅用于过滤，默认 `Date()`，单元测试可注入
    /// - 时钟回退保护：若 `now < 最早 entry.capturedAt`（系统时间被手动调后），
    ///   把 `now` 拉回 `capturedAt` 上限，避免 mode=.completedOnly 误把全部历史过滤掉。
    func cycles(limit: Int, now: Date = Date(), mode: UtilizationHistoryMode = .includeCurrent) -> [(resetsAt: Date, peakPercent: Double)] {
        guard limit > 0 else { return [] }

        // 时钟回退保护：现在不能早于任何 entry 的采样时间
        let earliestCapture = entries.map(\.capturedAt).min() ?? now
        let effectiveNow = max(now, earliestCapture)

        var peakByReset: [Date: Double] = [:]
        for entry in entries {
            guard let resetsAt = entry.resetsAt else { continue }
            if mode == .completedOnly, resetsAt > effectiveNow { continue }
            let current = peakByReset[resetsAt] ?? 0
            if entry.usedPercent > current {
                peakByReset[resetsAt] = entry.usedPercent
            }
        }
        return peakByReset
            .map { (resetsAt: $0.key, peakPercent: $0.value) }
            .sorted { $0.resetsAt > $1.resetsAt }
            .prefix(limit)
            .map { $0 }
    }
}

/// 磁盘文件内容：以 provider 为粒度，内部按 `modelId` 嵌套。
/// `modelId` 已含 provider+accountName+modelName，多账号天然隔离。
struct ModelUtilizationStoreData: Codable, Equatable {
    /// 旧版本 JSON 缺此字段或显式为 null 时，decode 仍要成功 ——
    /// `histories` 可选，缺失视为空。
    var histories: [String: ModelUtilizationHistory]?

    init(histories: [String: ModelUtilizationHistory] = [:]) {
        self.histories = histories
    }

    var historiesOrEmpty: [String: ModelUtilizationHistory] {
        histories ?? [:]
    }
}
