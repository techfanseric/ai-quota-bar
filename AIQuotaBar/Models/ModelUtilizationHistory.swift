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
    let modelId: String
    var entries: [UtilizationHistoryEntry] = []

    init(modelId: String, entries: [UtilizationHistoryEntry] = []) {
        self.modelId = modelId
        self.entries = entries
    }

    /// 按 `resetsAt` 分组取 peak，返回按时间倒序的最近 `limit` 个周期。
    /// - `includeCurrent`（默认）：所有 resetsAt 参与计算，in-progress 周期也会出现（最右一根）
    /// - `completedOnly`：仅 `resetsAt <= now` 参与计算
    /// - 同周期多个样本取 `max(usedPercent)`（in-progress 周期取周期内历史 peak）
    /// - 入参 `now` 仅用于过滤，默认 `Date()`，单元测试可注入
    func cycles(limit: Int, now: Date = Date(), mode: UtilizationHistoryMode = .includeCurrent) -> [(resetsAt: Date, peakPercent: Double)] {
        guard limit > 0 else { return [] }
        var peakByReset: [Date: Double] = [:]
        for entry in entries {
            guard let resetsAt = entry.resetsAt else { continue }
            if mode == .completedOnly, resetsAt > now { continue }
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
    var histories: [String: ModelUtilizationHistory] = [:]
}
