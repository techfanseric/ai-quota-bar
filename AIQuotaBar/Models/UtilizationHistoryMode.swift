import Foundation

/// 跨周期 utilization 柱图的当前周期显示模式。
/// - `includeCurrent`（默认）：当前进行中的周期也算一根柱（最右），采集到首个样本后立即可见。
/// - `completedOnly`：只看已结束周期。第一个周期结束（5h/7d）前整段柱图不渲染。
enum UtilizationHistoryMode: String, CaseIterable, Codable, Identifiable {
    case includeCurrent
    case completedOnly

    var id: String { rawValue }
}
