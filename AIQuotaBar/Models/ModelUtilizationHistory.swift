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
    static let resetBoundaryMergeTolerance: TimeInterval = 120

    /// 单个 model 历史样本上限：2200 条 × 1h 节流 ≈ 91 天（3 个月）。
    /// 超出按 `capturedAt` 升序丢最旧的（同步调用方在 `append` 后应调 `trimToLimit()`）。
    static let maxEntriesPerModel = 2200

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

        var buckets: [CycleBucket] = []
        for entry in entries.sorted(by: { ($0.resetsAt ?? .distantPast) < ($1.resetsAt ?? .distantPast) }) {
            guard let resetsAt = entry.resetsAt else { continue }
            guard entry.usedPercent > 0 else { continue }
            if mode == .completedOnly, resetsAt > effectiveNow { continue }
            if let index = buckets.lastIndex(where: {
                abs($0.resetsAt.timeIntervalSince(resetsAt)) <= Self.resetBoundaryMergeTolerance
            }) {
                buckets[index].resetsAt = max(buckets[index].resetsAt, resetsAt)
                buckets[index].peakPercent = max(buckets[index].peakPercent, entry.usedPercent)
            } else {
                buckets.append(CycleBucket(resetsAt: resetsAt, peakPercent: entry.usedPercent))
            }
        }
        return buckets
            .map { (resetsAt: $0.resetsAt, peakPercent: $0.peakPercent) }
            .sorted { $0.resetsAt > $1.resetsAt }
            .prefix(limit)
            .map { $0 }
    }

    private struct CycleBucket {
        var resetsAt: Date
        var peakPercent: Double
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

enum ModelUtilizationCycleMerger {
    static func mergeLiveCurrentCycle(
        _ historicalCycles: [(resetsAt: Date, peakPercent: Double)],
        model: ModelUsageData,
        limit: Int,
        now: Date,
        mode: UtilizationHistoryMode
    ) -> [(resetsAt: Date, peakPercent: Double)] {
        guard limit > 0 else { return [] }

        var peakByReset: [Date: Double] = [:]
        for cycle in historicalCycles {
            let peakPercent = clampedPercent(cycle.peakPercent)
            peakByReset[cycle.resetsAt] = max(peakByReset[cycle.resetsAt] ?? 0, peakPercent)
        }

        if mode == .includeCurrent,
           let endTime = model.endTime,
           endTime >= now,
           model.startTime.map({ $0 <= now }) ?? true,
           let liveUsedPercent = liveUsedPercent(for: model) {
            for reset in peakByReset.keys where abs(reset.timeIntervalSince(endTime)) <= ModelUtilizationHistory.resetBoundaryMergeTolerance {
                peakByReset.removeValue(forKey: reset)
            }
            peakByReset[endTime] = liveUsedPercent
        }

        return peakByReset
            .map { (resetsAt: $0.key, peakPercent: $0.value) }
            .sorted { $0.resetsAt > $1.resetsAt }
            .prefix(limit)
            .map { $0 }
    }

    private static func liveUsedPercent(for model: ModelUsageData) -> Double? {
        if let percent = model.currentIntervalRemainingPercent {
            return clampedPercent(100 - Double(percent))
        }
        guard model.currentIntervalTotal > 0 else { return nil }
        return clampedPercent(Double(model.currentIntervalUsedCount) / Double(model.currentIntervalTotal) * 100)
    }

    private static func clampedPercent(_ percent: Double) -> Double {
        max(0, min(100, percent))
    }
}
