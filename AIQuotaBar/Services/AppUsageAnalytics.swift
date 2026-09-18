import Foundation
import CryptoKit
import Observation

struct AnalyticsSchedule {
    static func isDue(active: Bool, now: Date, lastActive: Date?, lastPulse: Date?) -> Bool {
        if active {
            guard let lastActive else { return true }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            return !calendar.isDate(now, inSameDayAs: lastActive) || now.timeIntervalSince(lastActive) >= 900
        }
        return lastPulse.map { now.timeIntervalSince($0) >= 3600 } ?? true
    }
}

/// Opt-in product analytics. Separate random identity; never uses a Codex
/// account, cloud-sync device ID, hardware identifier, email or quota data.
@MainActor @Observable
final class AppUsageAnalytics {
    static let shared = AppUsageAnalytics()
    static let enabledKey = "anonymousAnalytics.enabled"
    private let defaults: UserDefaults
    private let session: URLSession
    private var timer: Timer?
    private var reportTask: Task<Void, Never>?
    private var pendingActivity = false
    private var lastFailure: Date?
    var status = ""
    var deleting = false
    var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Self.enabledKey)
            if enabled { start() }
            else { timer?.invalidate(); timer = nil; pendingActivity = false }
        }
    }

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults; self.session = session
        enabled = defaults.bool(forKey: Self.enabledKey)
    }
    func start() {
        guard enabled, !deleting else { return }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.send(active: false) }
            }
        }
        recordActivity()
    }
    func stop() { timer?.invalidate(); timer = nil }
    func recordActivity() { send(active: true) }

    private func installationToken() -> String {
        if let value = defaults.string(forKey: "anonymousAnalytics.token"), value.count == 64 { return value }
        let token = SymmetricKey(size: .bits256).withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
        defaults.set(token, forKey: "anonymousAnalytics.token")
        return token
    }
    private func send(active: Bool) {
        guard enabled, !deleting else { return }
        pendingActivity = pendingActivity || active
        guard reportTask == nil else { return }
        let now = Date(), isActive = pendingActivity
        pendingActivity = false
        guard AnalyticsSchedule.isDue(active: isActive, now: now,
            lastActive: defaults.object(forKey: "anonymousAnalytics.lastActive") as? Date,
            lastPulse: defaults.object(forKey: "anonymousAnalytics.lastPulse") as? Date),
            lastFailure.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let payload = ["installationToken": installationToken(), "event": isActive ? "active" : "heartbeat",
            "appVersion": UpdateChecker.currentAppVersion,
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            "osVersion": "\(os.majorVersion).\(os.minorVersion)"]
        reportTask = Task {
            do {
                try await post("pulse", payload: payload)
                defaults.set(now, forKey: "anonymousAnalytics.lastPulse")
                if isActive { defaults.set(now, forKey: "anonymousAnalytics.lastActive") }
                lastFailure = nil
                status = AppLanguage.current == .simplifiedChinese ? "匿名统计已上报" : "Anonymous statistics sent"
            } catch {
                lastFailure = Date()
                status = AppLanguage.current == .simplifiedChinese ? "统计暂未送达，将在后续使用时重试" : "Statistics not delivered; will retry during later use"
            }
            reportTask = nil
            if pendingActivity { send(active: true) }
        }
    }
    func deleteStatistics() async {
        guard !deleting else { return }
        deleting = true; enabled = false
        defer { deleting = false }
        await reportTask?.value
        guard let token = defaults.string(forKey: "anonymousAnalytics.token") else {
            status = AppLanguage.current == .simplifiedChinese ? "本机没有统计记录" : "No statistics from this installation"
            return
        }
        do {
            try await post("forget", payload: ["installationToken": token])
            for key in ["anonymousAnalytics.token", "anonymousAnalytics.lastPulse", "anonymousAnalytics.lastActive"] { defaults.removeObject(forKey: key) }
            lastFailure = nil
            status = AppLanguage.current == .simplifiedChinese ? "已停止统计并删除云端记录" : "Statistics disabled and server records deleted"
        } catch {
            status = AppLanguage.current == .simplifiedChinese ? "统计已关闭；删除未完成，请联网后重试" : "Statistics disabled; deletion failed, retry when online"
        }
    }
    private func post(_ action: String, payload: [String: String]) async throws {
        var request = URLRequest(url: URL(string: CloudSyncSettings.defaultEndpointURLString + "/v1/telemetry/" + action)!)
        request.httpMethod = "POST"; request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("AIQuotaBar", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer " + CloudSyncSettings.defaultServiceToken, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    }
}
