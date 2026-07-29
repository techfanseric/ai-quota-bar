import Foundation

private let notificationName = Notification.Name(
    "com.techfanseric.aiquotabar.codex-hook"
)

guard let input = try? FileHandle.standardInput.readToEnd(),
      !input.isEmpty,
      let payload = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
      let eventName = payload["hook_event_name"] as? String,
      let sessionID = payload["session_id"] as? String,
      !sessionID.isEmpty else {
    exit(EXIT_SUCCESS)
}

var userInfo: [String: String] = [
    "hook_event_name": eventName,
    "session_id": sessionID
]

for key in ["turn_id", "agent_id"] {
    if let value = payload[key] as? String, !value.isEmpty {
        userInfo[key] = value
    }
}

DistributedNotificationCenter.default().post(
    name: notificationName,
    object: nil,
    userInfo: userInfo
)
