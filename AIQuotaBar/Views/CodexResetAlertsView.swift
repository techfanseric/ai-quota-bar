import AppKit
import SwiftUI

@MainActor
struct CodexResetAlertsView: View {
    @State private var store: CodexResetAlertStore
    @State private var showsHistory = false
    let language: AppLanguage
    var onLayoutChange: () -> Void
    var onViewSource: (URL) -> Void

    init(language: AppLanguage, store: CodexResetAlertStore? = nil,
         onLayoutChange: @escaping () -> Void = {},
         onViewSource: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.language = language
        self.onLayoutChange = onLayoutChange
        self.onViewSource = onViewSource
        _store = State(initialValue: store ?? .shared)
    }

    private var chinese: Bool { language == .simplifiedChinese }
    private var visibleEntries: [CodexResetAlertStore.Entry] {
        if showsHistory { return store.history() }
        let unread = store.unread
        if !unread.isEmpty { return unread }
        return store.pinnedSignal.map { [$0] } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label(chinese ? "Codex 重置" : "Codex resets",
                      systemImage: store.unread.isEmpty ? "bell" : "bell.badge.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .help(chinese ? "未读时菜单栏闪烁，每 5 分钟通知，直到确认已读。" : "The menu-bar icon flashes and notifications repeat every 5 minutes until marked read.")
                Spacer(minLength: 4)
                if !store.unread.isEmpty {
                    Text("\(store.unread.count)").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .help(chinese ? "\(store.unread.count) 条未读" : "\(store.unread.count) unread")
                    iconButton("checkmark.circle", title: chinese ? "全部标为已读" : "Mark all read") {
                        store.acknowledge(ids: Set(store.unread.map(\.id)))
                    }
                }
                iconButton(showsHistory ? "clock.fill" : "clock.arrow.circlepath",
                           title: chinese ? (showsHistory ? "收起最近 30 天历史" : "查看最近 30 天历史")
                               : (showsHistory ? "Hide 30-day history" : "View 30-day history")) {
                    showsHistory.toggle()
                }
                .foregroundStyle(showsHistory ? Color.accentColor : Color.primary)
                iconButton("arrow.clockwise", title: chinese ? "检查两个来源" : "Check both sources") {
                    Task { await store.refresh(force: true) }
                }.disabled(store.isRefreshing)
            }
            if showsHistory {
                Text(chinese ? "最近 30 天 · \(visibleEntries.count) 条" : "Last 30 days · \(visibleEntries.count) updates")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            ForEach(visibleEntries) { entry in row(entry) }
            if showsHistory && visibleEntries.isEmpty {
                Text(chinese ? "最近 30 天暂无消息" : "No updates in the last 30 days")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            if store.notificationsDenied {
                Button(chinese ? "系统通知未开启 · 打开通知设置" : "Notifications disabled · Open settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }.font(.system(size: 9)).buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if !store.failures.isEmpty {
                Text(chinese ? "部分来源检查失败，稍后重试" : "Some feeds failed; retrying shortly")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .help(chinese ? "5 分钟后重试，已保存的未读消息继续提醒。" : "Retrying in 5 minutes. Saved unread updates still trigger reminders.")
            }
        }
        .padding(8)
        .transaction { $0.animation = nil }
        .onChange(of: showsHistory) { _, _ in onLayoutChange() }
        .onChange(of: store.failures) { _, _ in onLayoutChange() }
        .onChange(of: store.notificationsDenied) { _, _ in onLayoutChange() }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    private func row(_ entry: CodexResetAlertStore.Entry) -> some View {
        let alert = entry.alert
        return VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.top, 4)
            HStack(spacing: 8) {
                Text(compactTitle(alert.kind))
                    .font(.system(size: 11, weight: .semibold))
                    .help(alert.kind.title(language))
                Spacer(minLength: 4)
                iconButton("arrow.up.right.square", title: chinese ? "查看原文（关闭菜单）" : "View source (closes menu)") {
                    onViewSource(alert.url)
                }
                if !entry.isRead {
                    iconButton("checkmark.circle", title: chinese ? "确认已读（保持菜单打开）" : "Mark read (keeps menu open)") {
                        store.acknowledge(ids: [entry.id])
                    }
                } else {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11))
                        .foregroundStyle(.tertiary).frame(width: 18, height: 18)
                        .help(chinese ? "已读；最近的明确消息继续保留，不再提醒。" : "Read. The latest explicit update stays visible without further reminders.")
                        .accessibilityLabel(chinese ? "已读" : "Read")
                }
            }
            Text(alert.text).font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 4) {
                Button(alert.source.rawValue) { onViewSource(alert.source.url) }
                    .buttonStyle(.plain).help(chinese ? "打开数据来源（关闭菜单）" : "Open data source (closes menu)")
                Spacer(minLength: 4)
                Text(alert.publishedAt, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
            }
            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            if let deadline = alert.scheduledFor {
                Text((chinese ? "预告：" : "Scheduled: ") + deadline.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    private func compactTitle(_ kind: CodexResetAlert.Kind) -> String {
        switch kind {
        case .clue: return chinese ? "重置线索 · 未确认" : "Reset clue · unconfirmed"
        case .scheduled: return chinese ? "重置预告 · 待执行" : "Reset announced"
        case .confirmed: return chinese ? "站点报告已重置" : "Reset reported"
        case .banked: return chinese ? "Banked 重置" : "Banked reset"
        }
    }

    private func iconButton(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11))
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}
