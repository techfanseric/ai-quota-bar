import AppKit

enum CodexAppPresence {
    static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            UsageProvider.codex.companionAppMatcher.matches($0)
        }
    }
}
