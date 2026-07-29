import Foundation
import UserNotifications

final class ClashRecoveryNotificationService {
    static let shared = ClashRecoveryNotificationService()
    static let notificationActionKey = "notificationAction"
    static let openRoutesAction = "openClashRoutes"

    private init() {}

    func notifyRecovery(
        _ result: ClashRecoveryResult,
        language: AppLanguage
    ) async {
        guard result.didSwitchRoute else { return }

        let center = UNUserNotificationCenter.current()
        let settings = await notificationSettings(center: center)
        let authorized: Bool

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            authorized = true
        case .notDetermined:
            authorized = (try? await center.requestAuthorization(
                options: [.alert, .sound])) ?? false
        case .denied:
            authorized = false
        @unknown default:
            authorized = false
        }

        guard authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = language.clashRecoveryNotificationTitle()
        content.body = language.clashRecoveryNotificationBody(
            from: result.previousRoute,
            to: result.selectedRoute,
            delay: result.delay)
        content.sound = .default
        content.userInfo = [
            Self.notificationActionKey: Self.openRoutesAction
        ]

        let request = UNNotificationRequest(
            identifier: "clash-recovery-\(UUID().uuidString)",
            content: content,
            trigger: nil)

        await withCheckedContinuation { continuation in
            center.add(request) { _ in
                continuation.resume(returning: ())
            }
        }
    }

    private func notificationSettings(
        center: UNUserNotificationCenter
    ) async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }
}
