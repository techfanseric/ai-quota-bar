import Foundation
import UserNotifications

final class UpdateNotificationService {
    static let shared = UpdateNotificationService()

    private init() {}

    func notifyUpdateAvailable(
        language: AppLanguage,
        currentVersion: String,
        latestVersion: String,
        releaseURL: URL
    ) async {
        let center = UNUserNotificationCenter.current()

        let settings = await notificationSettings(center: center)
        let authorized: Bool
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            authorized = true
        case .notDetermined:
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        case .denied:
            authorized = false
        @unknown default:
            authorized = false
        }

        guard authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = language.updateNotificationTitle()
        content.body = language.updateNotificationBody(current: currentVersion, latest: latestVersion)
        content.sound = .default
        content.userInfo = ["releaseURL": releaseURL.absoluteString]

        let request = UNNotificationRequest(
            identifier: "app-update-\(latestVersion)",
            content: content,
            trigger: nil
        )

        await add(center: center, request: request)
    }

    private func notificationSettings(center: UNUserNotificationCenter) async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private func add(center: UNUserNotificationCenter, request: UNNotificationRequest) async {
        await withCheckedContinuation { continuation in
            center.add(request) { _ in
                continuation.resume(returning: ())
            }
        }
    }
}
