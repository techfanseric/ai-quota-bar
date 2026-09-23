import Foundation
import Observation

/// 右键 Clash 面板中的 OpenAI 分区。
enum ClashPanelSection: String, Codable, CaseIterable, Sendable {
    case routes
    case connections
}

/// 右键面板两个 OpenAI 分区（routes / connections）的折叠状态。
///
/// 「跟随运行中的应用」开启时由 Codex 的运行状态自动对齐；用户手动点击
/// 写入同一集合，最后一次操作生效。面板重开与 App 重启后保持。
@MainActor
@Observable
final class ClashPanelDisplayStore {
    static let storageKey = "clashPanelDisplayPreferences"

    private(set) var collapsedSections: Set<ClashPanelSection>

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(
                Set<ClashPanelSection>.self,
                from: data) {
            collapsedSections = decoded
        } else {
            collapsedSections = []
        }
    }

    var isRoutesCollapsed: Bool {
        collapsedSections.contains(.routes)
    }

    var isConnectionsCollapsed: Bool {
        collapsedSections.contains(.connections)
    }

    /// 用户手动点击分区标题，或自动对齐写入；变化时持久化。
    func setCollapsed(_ collapsed: Bool, section: ClashPanelSection) {
        var updated = collapsedSections
        if collapsed {
            updated.insert(section)
        } else {
            updated.remove(section)
        }
        guard updated != collapsedSections else { return }
        collapsedSections = updated
        persist()
    }

    func toggle(_ section: ClashPanelSection) {
        setCollapsed(!collapsedSections.contains(section), section: section)
    }

    /// 跟随运行中的应用开启时，把两段对齐到 Codex 的运行状态；
    /// 跟随关闭时不做任何自动变动（保持用户手动状态）。
    func alignWithCodexPresence(
        isRunning: Bool,
        followRunningAppsEnabled: Bool
    ) {
        guard followRunningAppsEnabled else { return }
        setCollapsed(!isRunning, section: .routes)
        setCollapsed(!isRunning, section: .connections)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(collapsedSections) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
