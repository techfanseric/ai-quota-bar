import Foundation

public enum SleepHelperConstants {
    public static let machServiceName = "com.techfanseric.aiquotabar.sleep-helper"
    public static let plistName = "com.techfanseric.aiquotabar.sleep-helper.plist"
    public static let helperExecutableName = "AIQuotaBarSleepHelper"
    public static let helperBundleIdentifier =
        "com.techfanseric.aiquotabar.sleep-helper"
    public static let mainAppBundleIdentifier = "com.techfanseric.aiquotabar"
    public static let privilegedHelperPath =
        "/Library/PrivilegedHelperTools/com.techfanseric.aiquotabar.sleep-helper"
    public static let launchDaemonPath =
        "/Library/LaunchDaemons/com.techfanseric.aiquotabar.sleep-helper.plist"
    public static let authorizedClientMarkerPath =
        "/var/db/com.techfanseric.aiquotabar.sleep-helper.authorized-client"
    public static let legacyPlistResourceName =
        "com.techfanseric.aiquotabar.sleep-helper.legacy.plist"
}

@objc public protocol AIQuotaBarSleepHelperProtocol {
    func healthCheck(
        withReply reply: @escaping (Bool, String) -> Void
    )

    func acquireClosedLidLease(
        _ leaseID: String,
        heartbeatTimeout: TimeInterval,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    func heartbeatClosedLidLease(
        _ leaseID: String,
        withReply reply: @escaping (Bool) -> Void
    )

    func releaseClosedLidLease(
        _ leaseID: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )
}
