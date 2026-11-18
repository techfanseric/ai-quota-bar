import CryptoKit
import Foundation
import UserNotifications

/// One registered quota window that has ended.
///
/// The identity deliberately includes the provider/account/model and the exact
/// end timestamp. A retry after a failed refresh may therefore retry the same
/// event, while the next cycle produces a different event.
struct QuotaCycleEndEvent: Equatable {
    enum Scope: String {
        case current
        case weekly
    }

    let provider: UsageProvider
    let accountName: String?
    let modelName: String
    let scope: Scope
    let startedAt: Date?
    let endedAt: Date
    let duration: TimeInterval?
    let endingRemainingText: String
    let endingRemainingPercent: Int?
    let endingUsedPercent: Int?
    let modelKey: String

    var identifier: String {
        let identity = [
            provider.rawValue,
            modelKey,
            scope.rawValue,
            String(Int(endedAt.timeIntervalSince1970)),
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
        return "quota-cycle-end-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func due(
        in providerData: [UsageProvider: UsageData],
        fetchableProviders: Set<UsageProvider>,
        now: Date
    ) -> [QuotaCycleEndEvent] {
        var events: [QuotaCycleEndEvent] = []
        for provider in fetchableProviders {
            guard let data = providerData[provider] else { continue }
            for model in data.models {
                // Codex Pool is a presentation aggregate built from per-account
                // Magpie rows. Notifying both would turn one account reset into
                // two notifications; the real per-account windows drive alerts.
                guard !model.isCodexPoolQuota,
                      !model.isCodexCurrentAccountQuota else { continue }
                if let endedAt = model.endTime, endedAt <= now {
                    events.append(Self.current(model: model, endedAt: endedAt))
                }
                // Some aggregate Codex rows mirror the same reset in both
                // fields. Different boundaries are distinct cycles; identical
                // boundaries are one notification.
                if let endedAt = model.weeklyEndTime,
                   endedAt <= now,
                   endedAt != model.endTime {
                    events.append(Self.weekly(model: model, endedAt: endedAt))
                }
            }
        }

        var seen = Set<String>()
        return events
            .filter { seen.insert($0.identifier).inserted }
            .sorted { lhs, rhs in
                if lhs.endedAt != rhs.endedAt { return lhs.endedAt < rhs.endedAt }
                if lhs.provider.rawValue != rhs.provider.rawValue {
                    return lhs.provider.rawValue < rhs.provider.rawValue
                }
                return lhs.modelKey < rhs.modelKey
            }
    }

    private static func current(model: ModelUsageData, endedAt: Date) -> QuotaCycleEndEvent {
        QuotaCycleEndEvent(
            provider: model.provider,
            accountName: model.accountName,
            modelName: model.modelName,
            scope: .current,
            startedAt: model.startTime,
            endedAt: endedAt,
            duration: model.startTime.map { endedAt.timeIntervalSince($0) },
            endingRemainingText: model.currentIntervalRemainingText,
            endingRemainingPercent: model.currentIntervalRemainingPercent,
            endingUsedPercent: Int(model.currentIntervalPercentageUsed.rounded()),
            modelKey: model.quotaIdentityKey)
    }

    private static func weekly(model: ModelUsageData, endedAt: Date) -> QuotaCycleEndEvent {
        let remainingPercent = model.weeklyRemainingPercent
        let remainingText: String
        if let remainingPercent {
            remainingText = "\(remainingPercent)%"
        } else if model.weeklyTotal > 0 {
            remainingText = "\(model.weeklyRemaining)\(model.valueSuffix ?? "")"
        } else {
            remainingText = "0"
        }
        let usedPercent = model.weeklyPercentageUsed.map { Int($0.rounded()) }
        return QuotaCycleEndEvent(
            provider: model.provider,
            accountName: model.accountName,
            modelName: model.modelName,
            scope: .weekly,
            startedAt: model.weeklyStartTime,
            endedAt: endedAt,
            duration: model.weeklyStartTime.map { endedAt.timeIntervalSince($0) },
            endingRemainingText: remainingText,
            endingRemainingPercent: remainingPercent,
            endingUsedPercent: usedPercent,
            modelKey: model.quotaIdentityKey)
    }
}

struct QuotaCycleEndNotificationPayload: Equatable {
    let identifier: String
    let title: String
    let subtitle: String
    let body: String
}

enum QuotaCycleEndNotificationFormatter {
    static func payloads(
        for events: [QuotaCycleEndEvent],
        refreshedData: [UsageProvider: UsageData],
        language: AppLanguage,
        masksAccountNames: Bool
    ) -> [QuotaCycleEndNotificationPayload] {
        events.map { payload(for: $0, refreshedData: refreshedData, language: language, masksAccountNames: masksAccountNames) }
    }

    private static func payload(
        for event: QuotaCycleEndEvent,
        refreshedData: [UsageProvider: UsageData],
        language: AppLanguage,
        masksAccountNames: Bool
    ) -> QuotaCycleEndNotificationPayload {
        let chinese = language == .simplifiedChinese
        let cycleName = Self.cycleName(for: event, chinese: chinese)
        let refreshed = refreshedModel(for: event, in: refreshedData)
        let refreshedRemaining = refreshed.map { remainingText(model: $0, scope: event.scope) }

        var identity = event.provider.displayName
        if let accountName = event.accountName, !accountName.isEmpty {
            identity += " · " + MenuAccountPrivacy.display(accountName, masked: masksAccountNames)
        }
        identity += " · " + event.modelName

        var oldSummary: String
        if let usedPercent = event.endingUsedPercent {
            oldSummary = chinese
                ? "上个\(cycleName)用掉 \(usedPercent)%，结束时剩 \(event.endingRemainingText)"
                : "Previous \(cycleName.lowercased()) used \(usedPercent)%, ending with \(event.endingRemainingText) left"
        } else {
            oldSummary = chinese
                ? "上个\(cycleName)结束时剩 \(event.endingRemainingText)"
                : "Previous \(cycleName.lowercased()) ended with \(event.endingRemainingText) left"
        }
        oldSummary += exhausted(event)
            ? (chinese ? "，已用完。" : " and was exhausted.")
            : (chinese ? "，未用完。" : " and was not exhausted.")

        let newSummary: String
        if let refreshedRemaining {
            if refreshedRemaining.hasPrefix("0") || refreshedRemaining == "0%" {
                newSummary = chinese
                    ? "刷新后新周期仍显示剩 \(refreshedRemaining)，服务端重置可能稍有延迟。"
                    : "After the refresh the new cycle still shows \(refreshedRemaining) left; the server-side reset may be slightly delayed."
            } else {
                newSummary = chinese
                    ? "刷新后新周期剩 \(refreshedRemaining)。"
                    : "After the refresh, the new cycle has \(refreshedRemaining) left."
            }
        } else {
            newSummary = chinese
                ? "新周期状态待下次成功刷新确认。"
                : "The new-cycle state will be confirmed on the next successful refresh."
        }

        return QuotaCycleEndNotificationPayload(
            identifier: event.identifier,
            title: chinese ? "额度周期已重置" : "Quota cycle reset",
            subtitle: "\(identity) · \(cycleName)",
            body: "\(oldSummary) \(newSummary)")
    }

    private static func refreshedModel(
        for event: QuotaCycleEndEvent,
        in data: [UsageProvider: UsageData]
    ) -> ModelUsageData? {
        data[event.provider]?.models.first { model in
            model.quotaIdentityKey == event.modelKey
        }
    }

    private static func remainingText(model: ModelUsageData, scope: QuotaCycleEndEvent.Scope) -> String {
        switch scope {
        case .current:
            return model.currentIntervalRemainingText
        case .weekly:
            if let percent = model.weeklyRemainingPercent { return "\(percent)%" }
            return "\(model.weeklyRemaining)\(model.valueSuffix ?? "")"
        }
    }

    private static func exhausted(_ event: QuotaCycleEndEvent) -> Bool {
        if let percent = event.endingRemainingPercent { return percent <= 0 }
        return event.endingRemainingText.hasPrefix("0")
    }

    private static func cycleName(for event: QuotaCycleEndEvent, chinese: Bool) -> String {
        if event.scope == .weekly { return chinese ? "周周期" : "Weekly cycle" }
        if let duration = event.duration {
            if (4 * 3600 ... 18 * 3600).contains(duration) {
                return chinese ? "5 小时周期" : "5h cycle"
            }
            if (27 * 86_400 ... 35 * 86_400).contains(duration) {
                return chinese ? "月度周期" : "monthly cycle"
            }
        }
        return chinese ? "当前周期" : "current cycle"
    }
}

@MainActor
protocol QuotaCycleEndNotifying {
    func deliver(_ payload: QuotaCycleEndNotificationPayload) async -> Bool
}

@MainActor
final class QuotaCycleEndNotificationService: QuotaCycleEndNotifying {
    static let shared = QuotaCycleEndNotificationService()

    private init() {}

    func deliver(_ payload: QuotaCycleEndNotificationPayload) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
                return false
            }
        case .denied:
            return false
        case .authorized, .provisional, .ephemeral:
            break
        @unknown default:
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.subtitle = payload.subtitle
        content.body = payload.body
        content.sound = .default
        content.interruptionLevel = .active
        do {
            try await center.add(UNNotificationRequest(
                identifier: payload.identifier,
                content: content,
                trigger: nil))
            return true
        } catch {
            NSLog("aiquotabar: quota-cycle notification failed: %@", error.localizedDescription)
            return false
        }
    }
}

@MainActor
final class QuotaCycleEndNotificationCoordinator {
    private static let deliveredKey = "quotaCycleEndNotificationsDeliveredAt"
    private static let retention: TimeInterval = 60 * 86_400

    private let notifier: QuotaCycleEndNotifying
    private let defaults: UserDefaults

    init(
        notifier: QuotaCycleEndNotifying? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.notifier = notifier ?? QuotaCycleEndNotificationService.shared
        self.defaults = defaults
    }

    func deliver(
        _ events: [QuotaCycleEndEvent],
        refreshedData: [UsageProvider: UsageData],
        language: AppLanguage,
        masksAccountNames: Bool
    ) async {
        let payloads = QuotaCycleEndNotificationFormatter.payloads(
            for: events,
            refreshedData: refreshedData,
            language: language,
            masksAccountNames: masksAccountNames)

        for payload in payloads where deliveredAt(identifier: payload.identifier) == nil {
            guard await notifier.deliver(payload) else { continue }
            markDelivered(identifier: payload.identifier)
        }
    }

    private func deliveredAt(identifier: String) -> Date? {
        deliveredByID()[identifier].flatMap { Date(timeIntervalSince1970: $0) }
    }

    private func markDelivered(identifier: String) {
        var delivered = deliveredByID()
        delivered[identifier] = Date().timeIntervalSince1970
        let cutoff = Date().addingTimeInterval(-Self.retention).timeIntervalSince1970
        delivered = delivered.filter { $0.value >= cutoff }
        defaults.set(delivered, forKey: Self.deliveredKey)
    }

    private func deliveredByID() -> [String: Double] {
        defaults.dictionary(forKey: Self.deliveredKey)?.compactMapValues { value in
            (value as? NSNumber)?.doubleValue
        } ?? [:]
    }
}
