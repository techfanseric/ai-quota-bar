import AppKit
import Foundation
import Observation

/// Durable inbox. Acknowledgement always refers to the displayed revision, so
/// clicking an old notification cannot accidentally clear a newer confirmation.
@MainActor @Observable
final class CodexResetAlertStore {
    static let shared = CodexResetAlertStore()
    nonisolated static let pollInterval: TimeInterval = 60
    nonisolated static let reminderInterval: TimeInterval = 5 * 60
    /// Reset announcements remain in the local archive for 30 days so their
    /// revisions can be deduplicated, but the UI only displays the last 24h.
    nonisolated static let historyInterval: TimeInterval = 30 * 24 * 60 * 60
    nonisolated static let displayInterval: TimeInterval = 24 * 60 * 60
    static let storageKey = "codexResetAlerts.v1"

    struct Entry: Codable, Equatable, Identifiable {
        let alert: CodexResetAlert
        var isRead: Bool
        var id: String { alert.id }
    }
    private struct Archive: Codable {
        var entries: [Entry] = []
        var seen: Set<String> = []
        var initialized: Set<CodexResetFeed> = []
    }

    private(set) var entries: [Entry]
    private(set) var lastChecked: [CodexResetFeed: Date] = [:]
    private(set) var failures: Set<CodexResetFeed> = []
    private(set) var notificationsDenied = false
    private(set) var isRefreshing = false
    @ObservationIgnored private var archive: Archive
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let notifications: any CodexResetNotifying
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var nextAttempt: [CodexResetFeed: Date] = [:]
    @ObservationIgnored private var lastReminder: Date?
    @ObservationIgnored private var lastRemindedIDs: Set<String> = []
    @ObservationIgnored private var isNotifying = false

    var unread: [Entry] { entries.filter { !$0.isRead } }

    /// The last explicit announcement stays useful after acknowledgement.
    /// Purely speculative clues stay in the inbox/history instead.
    var pinnedSignal: Entry? { Self.latestReliable(in: entries) }

    private static func latestReliable(in entries: [Entry]) -> Entry? {
        entries.filter { !$0.alert.isLocalTest && $0.alert.kind != .clue }
            .max { $0.alert.publishedAt < $1.alert.publishedAt }
    }

    private static func retainedEntries(_ entries: [Entry], now: Date) -> [Entry] {
        let pinnedID = latestReliable(in: entries)?.id
        return entries.filter {
            if $0.alert.isLocalTest { return !$0.isRead }
            return !$0.isRead || $0.id == pinnedID
                || $0.alert.publishedAt >= now.addingTimeInterval(-historyInterval)
        }
    }

    init(defaults: UserDefaults = .standard, session: URLSession = .shared,
         notifications: (any CodexResetNotifying)? = nil) {
        self.defaults = defaults
        self.session = session
        self.notifications = notifications ?? CodexResetNotificationService.shared
        var saved = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(Archive.self, from: $0) } ?? Archive()
        let hadLocalTests = saved.entries.contains { $0.alert.isLocalTest }
        saved.entries = Self.retainedEntries(saved.entries.filter { !$0.alert.isLocalTest }, now: .now)
        archive = saved
        entries = saved.entries
        persist()
        if hadLocalTests && unread.isEmpty { self.notifications.clearDeliveredNotification() }
    }

    /// In-memory preview using the real unread/rendering/notification path.
    func triggerLocalTest(now: Date = .now) async {
        entries.removeAll { $0.alert.isLocalTest }
        let chinese = AppLanguage.current == .simplifiedChinese
        let alert = CodexResetAlert(key: "local-test:\(UUID())", source: .reset,
            kind: .clue, publishedAt: now,
            text: chinese
                ? "黄点与额度圆环闪烁测试。这是本机测试，不代表账号额度已重置；确认已读即可结束。"
                : "Yellow dot and quota ring preview. Local test only; your quota has not reset. Mark read to stop.",
            url: CodexResetAlert.Source.reset.url, scheduledFor: nil)
        entries.insert(Entry(alert: alert, isRead: false), at: 0)
        NSLog("aiquotabar: local reset-alert preview triggered")
        await remindIfNeeded(now: now)
    }

    func history(now: Date = .now) -> [Entry] {
        entries.filter { $0.alert.publishedAt >= now.addingTimeInterval(-Self.historyInterval) }
    }

    /// Entries eligible for the reset panel. Older records remain archived for
    /// deduplication and notification bookkeeping, but never appear in the UI.
    func displayEntries(now: Date = .now) -> [Entry] {
        entries.filter {
            $0.alert.publishedAt >= now.addingTimeInterval(-Self.displayInterval)
        }
    }

    func displayUnread(now: Date = .now) -> [Entry] {
        displayEntries(now: now).filter { !$0.isRead }
    }

    func displayPinnedSignal(now: Date = .now) -> Entry? {
        Self.latestReliable(in: displayEntries(now: now))
    }

    func start() {
        guard loop == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh(force: true) }
        }
        loop = Task { @MainActor [weak self] in
            // Remind about persisted unread items even while offline.
            await self?.remindIfNeeded()
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(Self.pollInterval)) }
                catch { return }
                guard self != nil else { return }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    func refresh(force: Bool = false, now: Date = .now) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let feeds = CodexResetFeed.allCases.filter { force || now >= nextAttempt[$0, default: .distantPast] }
        // Each feed commits independently: one unavailable site never suppresses
        // fresh news from the other, or marks the failed feed as initialized.
        await withTaskGroup(of: (CodexResetFeed, Data?, TimeInterval).self) { group in
            for feed in feeds {
                let session = session
                group.addTask {
                    do {
                        var request = URLRequest(url: feed.url, cachePolicy: .reloadIgnoringLocalCacheData)
                        request.timeoutInterval = 12
                        request.setValue("application/json", forHTTPHeaderField: "Accept")
                        request.setValue("AIQuotaBar/ResetAlerts", forHTTPHeaderField: "User-Agent")
                        let (data, response) = try await session.data(for: request)
                        guard let http = response as? HTTPURLResponse else {
                            return (feed, nil, Self.reminderInterval)
                        }
                        guard http.statusCode == 200 else {
                            let retry = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 0
                            return (feed, nil, max(Self.reminderInterval, retry.isFinite ? retry : 0))
                        }
                        return (feed, data, Self.pollInterval)
                    } catch { return (feed, nil, Self.reminderInterval) }
                }
            }
            for await (feed, data, retryDelay) in group {
                guard !Task.isCancelled else { continue }
                do {
                    guard let data else { throw URLError(.badServerResponse) }
                    let alerts = try feed.decode(data, now: now)
                    ingest(alerts, feed: feed, now: now)
                    lastChecked[feed] = now
                    failures.remove(feed)
                    nextAttempt[feed] = now.addingTimeInterval(Self.pollInterval)
                } catch {
                    failures.insert(feed)
                    nextAttempt[feed] = now.addingTimeInterval(max(Self.reminderInterval, retryDelay))
                }
            }
        }
        guard !Task.isCancelled else { return }
        pruneReadHistory(now: now)
        await remindIfNeeded(now: now)
    }

    func ingest(_ alerts: [CodexResetAlert], feed: CodexResetFeed, now: Date = .now) {
        let firstFetch = !archive.initialized.contains(feed)
        let unseen = alerts.filter { !archive.seen.contains($0.id) }
        guard firstFetch || !unseen.isEmpty else { return }
        archive.initialized.insert(feed)
        var updated = entries
        for alert in unseen where !archive.seen.contains(alert.id) {
            archive.seen.insert(alert.id)
            if let existing = updated.first(where: { $0.alert.key == alert.key }),
               existing.alert.kind == .confirmed,
               alert.kind == .scheduled || alert.kind == .clue {
                continue // A late/stale preview cannot roll a confirmation back.
            }
            // Baseline old history without alerting. Afterwards even delayed
            // publications are delivered, independent of their announcement age.
            // Another feed from this site may already have established this
            // announcement. Its newly observed revision is an update, even if
            // this particular feed is succeeding for the first time.
            let historical = firstFetch && !updated.contains { $0.alert.key == alert.key }
                && alert.publishedAt < now.addingTimeInterval(-24 * 3600)
            // Status + history share identities within codex-resets.com. A stale
            // history response must not overwrite a scheduled/confirmed revision.
            updated.removeAll { $0.alert.key == alert.key }
            updated.append(Entry(alert: alert, isRead: historical))
        }
        updated.sort { $0.alert.publishedAt > $1.alert.publishedAt }
        // The 30-day history, older unread messages, and the one pinned signal
        // have independent lifetimes. Reading the pin never re-arms a reminder.
        entries = Self.retainedEntries(updated, now: now)
        persist()
    }

    func acknowledge(ids: Set<String>) {
        guard entries.contains(where: { !$0.isRead && ids.contains($0.id) }) else { return }
        let updated = entries.map { entry in
            var result = entry
            if ids.contains(entry.id) { result.isRead = true }
            return result
        }
        entries = Self.retainedEntries(updated, now: .now)
        persist()
        // A stale notification action must not remove a newer banner either.
        // Keep the current summary visible when other messages remain unread.
        if unread.isEmpty { notifications.clearDeliveredNotification() }
        NSLog("aiquotabar: reset-alert acknowledged; unread=%ld", unread.count)
    }

    /// Removes announcements from the panel immediately. Their revisions stay
    /// in `seen`, so the next polling response cannot make the same message
    /// reappear; a newer revision is still delivered normally.
    func dismiss(ids: Set<String>) {
        guard entries.contains(where: { ids.contains($0.id) }) else { return }
        entries.removeAll { ids.contains($0.id) }
        persist()
        if unread.isEmpty { notifications.clearDeliveredNotification() }
        NSLog("aiquotabar: reset-alert dismissed; remaining=%ld", entries.count)
    }

    private func pruneReadHistory(now: Date) {
        let retained = Self.retainedEntries(entries, now: now)
        guard retained != entries else { return }
        entries = retained
        persist()
    }

    private func persist() {
        archive.entries = entries.filter { !$0.alert.isLocalTest }
        if let data = try? JSONEncoder().encode(archive) { defaults.set(data, forKey: Self.storageKey) }
    }

    func reminderIsDue(now: Date) -> Bool {
        let ids = Set(unread.map(\.id))
        guard !ids.isEmpty else { return false }
        return !ids.isSubset(of: lastRemindedIDs)
            || lastReminder.map { now.timeIntervalSince($0) >= Self.reminderInterval } != false
    }

    private func remindIfNeeded(now: Date = .now) async {
        guard !isNotifying, reminderIsDue(now: now) else { return }
        isNotifying = true
        defer { isNotifying = false }
        let snapshot = unread.map(\.alert)
        let result = await notifications.notify(snapshot, language: AppLanguage.current)
        notificationsDenied = result == .denied
        // Throttle denied/failed deliveries too; the menu-bar reminder persists.
        lastReminder = now
        lastRemindedIDs = Set(snapshot.map(\.id))
        // Acknowledgement may arrive while authorization or delivery is pending.
        if unread.isEmpty { notifications.clearDeliveredNotification() }
    }
}
