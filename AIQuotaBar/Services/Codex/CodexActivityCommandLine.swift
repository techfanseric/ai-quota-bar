import Foundation

enum CodexActivityCommandLine {
    static func runIfRequested(
        arguments: [String] = CommandLine.arguments
    ) -> Int32? {
        guard arguments.contains("--codex-activity-status") else {
            return nil
        }

        let snapshot = CodexLocalActivityDetector()
            .detectSnapshot(now: Date())
        print(
            "codex activity: \(snapshot.activeSessionIDs.count) active "
                + (snapshot.activeSessionIDs.count == 1 ? "task" : "tasks")
        )
        return EXIT_SUCCESS
    }
}
