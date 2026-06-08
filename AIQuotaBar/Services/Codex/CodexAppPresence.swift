import AppKit

enum CodexAppPresence {
    private static let knownBundleIDs: Set<String> = [
        "com.openai.codex",
        "com.openai.chatgpt.codex",
        "com.openai.chat",
    ]

    static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            if let bundleIdentifier = app.bundleIdentifier?.lowercased(),
               knownBundleIDs.contains(bundleIdentifier) || bundleIdentifier.contains("codex") {
                return true
            }

            let processName = (app.localizedName ?? app.executableURL?.lastPathComponent ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return processName == "codex"
        }
    }
}
