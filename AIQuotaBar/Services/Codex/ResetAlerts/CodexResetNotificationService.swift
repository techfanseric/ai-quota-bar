import Foundation
import UserNotifications

@MainActor
protocol CodexResetNotifying {
    func notify(_ alerts: [CodexResetAlert], language: AppLanguage) async -> CodexResetNotificationService.Delivery
    func clearDeliveredNotification()
}

@MainActor
final class CodexResetNotificationService: CodexResetNotifying {
    static let shared = CodexResetNotificationService()
    nonisolated static let category = "codex-reset-alert"
    nonisolated static let acknowledgeAction = "codex-reset-acknowledge"
    nonisolated static let idsKey = "codexResetAlertIDs"
    nonisolated static let identifier = "codex-reset-unread"

    enum Delivery { case delivered, denied, failed }

    func notify(_ alerts: [CodexResetAlert], language: AppLanguage) async -> Delivery {
        guard let latest = alerts.first else { return .failed }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return .denied }
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: break
        @unknown default: return .denied
        }
        let chinese = language == .simplifiedChinese
        let action = UNNotificationAction(identifier: Self.acknowledgeAction,
            title: chinese ? "确认本次消息已读" : "Mark these updates read", options: [])
        var categories = await center.notificationCategories()
        categories = categories.filter { $0.identifier != Self.category }
        categories.insert(UNNotificationCategory(identifier: Self.category, actions: [action], intentIdentifiers: []))
        center.setNotificationCategories(categories)

        let content = UNMutableNotificationContent()
        content.title = chinese ? "Codex 重置消息 · \(alerts.count) 条未读" : "Codex reset updates · \(alerts.count) unread"
        content.subtitle = latest.title(language)
        content.body = "\(latest.sourceTitle(language)): \(latest.text.prefix(350))\n"
            + (chinese ? "请在菜单中查看并确认已读；未确认将继续提醒。" : "Review and mark read in the menu. Reminders continue until acknowledged.")
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.interruptionLevel = .timeSensitive
        content.userInfo = [Self.idsKey: alerts.map(\.id)]
        do {
            try await center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil))
            NSLog("aiquotabar: reset-alert notification submitted; unread=%ld", alerts.count)
            return .delivered
        } catch {
            NSLog("aiquotabar: reset-alert notification failed: %@", error.localizedDescription)
            return .failed
        }
    }

    func clearDeliveredNotification() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
    }
}
