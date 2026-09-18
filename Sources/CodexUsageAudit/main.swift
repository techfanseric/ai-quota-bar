import Foundation
import CodexLocalUsageCore

/// Read-only source audit; writes only to the explicitly supplied scratch database.
@main struct CodexUsageAudit {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { throw UsageFailure.invalid("Usage: CodexUsageAudit <codex-root> <scratch-database>") }
        let store = try UsageStore(url: URL(fileURLWithPath: args[2]))
        let begin = Date()
        let scan = try await store.scan(root: URL(fileURLWithPath: args[1]))
        let firstSeconds = Date().timeIntervalSince(begin)
        let secondBegin = Date()
        let firstIDs = Set(scan.events.map(\.id))
        let second = try await store.scan(root: URL(fileURLWithPath: args[1]))
        let secondSeconds = Date().timeIntervalSince(secondBegin)
        let reopened = try UsageStore(url: URL(fileURLWithPath: args[2]))
        let persisted = try await reopened.events()
        let summary = UsageSummary(events: scan.events)
        let payload: [String: Any] = ["files": scan.files, "records": scan.events.count,
            "input": summary.tokens.input, "output": summary.tokens.output, "cached": summary.tokens.cached,
            "cacheWrite": summary.tokens.cacheWrite, "issues": scan.issues, "deferred": scan.deferred,
            "incompleteTails": scan.incomplete, "rescanRemovedRecords": firstIDs.subtracting(Set(second.events.map(\.id))).count,
            "newRecordsWhileScanning": second.events.count - scan.events.count,
            "persistedRecords": persisted.count, "elapsedSeconds": Date().timeIntervalSince(begin), "firstScanSeconds": firstSeconds, "secondScanSeconds": secondSeconds,
            "models": summary.byModel]
        print(String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted,.sortedKeys]), as: UTF8.self))
    }
}
