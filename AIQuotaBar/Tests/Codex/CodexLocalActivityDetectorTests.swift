import Foundation
import SQLite3
import XCTest
@testable import AIQuotaBar

final class CodexLocalActivityDetectorTests: XCTestCase {
    func testDetectsAlreadyRunningTasksAndExcludesCompletedTasks() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let activeRollout = fixture.directory
            .appendingPathComponent("active.jsonl")
        let completedRollout = fixture.directory
            .appendingPathComponent("completed.jsonl")
        let staleRollout = fixture.directory
            .appendingPathComponent("stale.jsonl")

        try rollout(
            [
                event("task_started"),
                event("agent_reasoning"),
                event("token_count")
            ],
            repeatingMiddleLine: 40
        ).write(to: activeRollout, atomically: true, encoding: .utf8)
        try rollout([
            event("task_started"),
            event("agent_reasoning"),
            event("task_complete")
        ]).write(to: completedRollout, atomically: true, encoding: .utf8)
        try rollout([
            event("task_started")
        ]).write(to: staleRollout, atomically: true, encoding: .utf8)

        try fixture.insert(
            id: "active-thread",
            rolloutURL: activeRollout,
            updatedAt: 9_990
        )
        try fixture.insert(
            id: "completed-thread",
            rolloutURL: completedRollout,
            updatedAt: 9_995
        )
        try fixture.insert(
            id: "stale-thread",
            rolloutURL: staleRollout,
            updatedAt: 1_000
        )

        let detector = CodexLocalActivityDetector(
            stateDatabaseURL: fixture.databaseURL,
            recentActivityWindow: 3_600,
            candidateLimit: 32,
            maximumRolloutScanBytes: 64 * 1_024,
            rolloutReadChunkBytes: 64
        )

        let snapshot = detector.detectSnapshot(
            now: Date(timeIntervalSince1970: 10_000)
        )

        XCTAssertEqual(snapshot.activeSessionIDs, ["active-thread"])
        XCTAssertEqual(
            snapshot.lastEventAt,
            Date(timeIntervalSince1970: 9_990)
        )
    }

    func testDefaultDatabaseFollowsConfiguredCodexHome() {
        let url = CodexLocalActivityDetector.defaultStateDatabaseURL(
            environment: ["CODEX_HOME": "/tmp/custom-codex-home"],
            homeDirectory: URL(fileURLWithPath: "/tmp/unused")
        )

        XCTAssertEqual(
            url.path,
            "/tmp/custom-codex-home/state_5.sqlite"
        )
    }

    func testActiveTaskCollectsSanitizedDisplayMetadata() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 15_000)
        let rolloutURL = fixture.directory.appendingPathComponent("metadata.jsonl")
        try writeRollout([
            try eventRecord(
                "task_started",
                turnID: "metadata-turn",
                timestamp: now.addingTimeInterval(-10)),
        ], to: rolloutURL)
        try fixture.insert(
            id: "metadata-thread",
            rolloutURL: rolloutURL,
            updatedAt: 14_999,
            threadSource: "user",
            source: "vscode",
            title: "Review active task details",
            cwd: "/Users/private/ai-quota-bar",
            model: "gpt-5.6-sol",
            reasoningEffort: "xhigh",
            modelProvider: "openai",
            sandboxPolicy: #"{"type":"danger-full-access"}"#,
            approvalMode: "never",
            tokensUsed: 12_345,
            gitBranch: "codex/task-barrage",
            cliVersion: "1.2.3")

        let activity = try XCTUnwrap(
            makeDetector(fixture).detectSnapshot(now: now)
                .sessionActivities["metadata-thread"])

        XCTAssertEqual(activity.title, "Review active task details")
        XCTAssertEqual(activity.projectName, "ai-quota-bar")
        XCTAssertEqual(activity.gitBranch, "codex/task-barrage")
        XCTAssertEqual(activity.source, "vscode / user")
        XCTAssertEqual(activity.model, "gpt-5.6-sol")
        XCTAssertEqual(activity.modelProvider, "openai")
        XCTAssertEqual(activity.reasoningEffort, "xhigh")
        XCTAssertEqual(activity.sandboxPolicy, "danger-full-access")
        XCTAssertEqual(activity.approvalMode, "never")
        XCTAssertEqual(activity.tokensUsed, 12_345)
        XCTAssertEqual(activity.cliVersion, "1.2.3")
        XCTAssertEqual(
            activity.createdAt,
            Date(timeIntervalSince1970: 14_999 - 3_600))
        XCTAssertEqual(activity.activeSubtaskCount, 0)
        XCTAssertNil(CodexTaskMetadataSanitizer.sanitize(
            "sk-METADATA_SECRET_SENTINEL_123456"))
        XCTAssertNil(CodexTaskMetadataSanitizer.sanitize(
            "/Users/private/secret-project"))
    }

    func testIncrementalParserRetainsPartialTailUntilLineCompletes()
        throws
    {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 10_000)
        let rolloutURL = fixture.directory
            .appendingPathComponent("partial.jsonl")
        let started = try eventRecord(
            "task_started",
            turnID: "turn-partial",
            timestamp: now.addingTimeInterval(-4))
        let progress = try commentaryRecord(
            "Finished the safe parser fixture",
            timestamp: now.addingTimeInterval(-2))
        let splitIndex = progress.utf8.count / 2
        let prefix = Data(progress.utf8.prefix(splitIndex))
        let suffix = Data(progress.utf8.dropFirst(splitIndex))
        var initial = Data((started + "\n").utf8)
        initial.append(prefix)
        try initial.write(to: rolloutURL)
        try fixture.insert(
            id: "partial-thread",
            rolloutURL: rolloutURL,
            updatedAt: 9_998)

        let detector = makeDetector(fixture)
        let beforeCompletion = detector.detectSnapshot(now: now)

        XCTAssertEqual(
            beforeCompletion.activeSessionIDs,
            ["partial-thread"])
        XCTAssertTrue(
            beforeCompletion.sessionActivities[
                "partial-thread"
            ]?.progressLines.isEmpty == true)

        try append(suffix + Data("\n".utf8), to: rolloutURL)
        let afterCompletion = detector.detectSnapshot(now: now)

        XCTAssertEqual(
            afterCompletion.sessionActivities[
                "partial-thread"
            ]?.progressLines.map(\.text),
            ["Finished the safe parser fixture"])
    }

    func testBootstrapRecoversActiveTurnBeforeBoundedTailWindow() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 16_000)
        let rolloutURL = fixture.directory
            .appendingPathComponent("large-active.jsonl")
        let oversizedToolOutput = try responseItemRecord(
            type: "function_call_output",
            fields: [
                "call_id": "large-output",
                "output": String(repeating: "x", count: 17 * 1_024 * 1_024),
            ],
            timestamp: now.addingTimeInterval(-5))
        try writeRollout([
            try eventRecord(
                "task_started",
                turnID: "large-active-turn",
                timestamp: now.addingTimeInterval(-10)),
            oversizedToolOutput,
            try commentaryRecord(
                "Still running after a large tool result",
                timestamp: now.addingTimeInterval(-1)),
        ], to: rolloutURL)
        try fixture.insert(
            id: "large-active-thread",
            rolloutURL: rolloutURL,
            updatedAt: 15_999)

        let snapshot = CodexLocalActivityDetector(
            stateDatabaseURL: fixture.databaseURL,
            recentActivityWindow: 3_600,
            candidateLimit: 32,
            maximumRolloutScanBytes: 64 * 1_024,
            rolloutReadChunkBytes: 4 * 1_024
        ).detectSnapshot(now: now)

        XCTAssertEqual(snapshot.activeSessionIDs, ["large-active-thread"])
        XCTAssertEqual(
            snapshot.sessionActivities["large-active-thread"]?
                .progressLines.map(\.text),
            ["Still running after a large tool result"])
    }

    func testTruncateAndAtomicReplaceRebuildParserState() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 20_000)
        let rolloutURL = fixture.directory
            .appendingPathComponent("replaced.jsonl")
        try writeRollout([
            try eventRecord(
                "task_started",
                turnID: "turn-before",
                timestamp: now.addingTimeInterval(-5)),
            try commentaryRecord(
                "This line belongs to the old file",
                timestamp: now.addingTimeInterval(-4)),
        ], to: rolloutURL)
        try fixture.insert(
            id: "replaced-thread",
            rolloutURL: rolloutURL,
            updatedAt: 19_999)
        let detector = makeDetector(fixture)

        XCTAssertEqual(
            detector.detectSnapshot(now: now)
                .sessionActivities["replaced-thread"]?
                .progressLines.map(\.text),
            ["This line belongs to the old file"])

        // A same-inode truncation must discard all prior active/progress
        // state instead of replaying bytes at a stale offset.
        try writeRollout([
            try eventRecord(
                "task_complete",
                turnID: "turn-before",
                timestamp: now.addingTimeInterval(-2)),
        ], to: rolloutURL, atomically: false)
        XCTAssertTrue(
            detector.detectSnapshot(now: now).activeSessionIDs.isEmpty)

        // Atomic replacement changes the inode. It must be treated as a new
        // stream even if its size happens to resemble the previous file.
        try writeRollout([
            try eventRecord(
                "task_started",
                turnID: "turn-after",
                timestamp: now.addingTimeInterval(-1)),
            try commentaryRecord(
                "Only the replacement survives",
                timestamp: now),
        ], to: rolloutURL, atomically: true)
        let replacement = detector.detectSnapshot(now: now)
        XCTAssertEqual(replacement.activeSessionIDs, ["replaced-thread"])
        XCTAssertEqual(
            replacement.sessionActivities["replaced-thread"]?
                .progressLines.map(\.text),
            ["Only the replacement survives"])
    }

    func testCompactionClearsSensitiveDerivedStateButKeepsLifecycle()
        throws
    {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 30_000)
        let rolloutURL = fixture.directory
            .appendingPathComponent("compacted.jsonl")
        try writeRollout([
            try eventRecord(
                "task_started",
                turnID: "turn-compacted",
                timestamp: now.addingTimeInterval(-5)),
            try commentaryRecord(
                "Pre-compaction progress must disappear",
                timestamp: now.addingTimeInterval(-4)),
        ], to: rolloutURL)
        try fixture.insert(
            id: "compacted-thread",
            rolloutURL: rolloutURL,
            updatedAt: 29_999)
        let detector = makeDetector(fixture)
        XCTAssertFalse(
            detector.detectSnapshot(now: now)
                .sessionActivities["compacted-thread"]!
                .progressLines.isEmpty)

        try append(
            Data((try rootRecord(
                type: "compacted",
                payload: [
                    "replacement":
                        "Bearer COMPACTION_SECRET_MUST_NOT_SURVIVE",
                ],
                timestamp: now.addingTimeInterval(-2)) + "\n").utf8),
            to: rolloutURL)
        let compacted = detector.detectSnapshot(now: now)

        XCTAssertEqual(compacted.activeSessionIDs, ["compacted-thread"])
        XCTAssertTrue(
            compacted.sessionActivities["compacted-thread"]?
                .progressLines.isEmpty == true)

        try append(
            Data((try commentaryRecord(
                "Post-compaction safe update",
                timestamp: now) + "\n").utf8),
            to: rolloutURL)
        XCTAssertEqual(
            detector.detectSnapshot(now: now)
                .sessionActivities["compacted-thread"]?
                .progressLines.map(\.text),
            ["Post-compaction safe update"])
    }

    func testSubagentThreadsAreGroupedIntoRootSessionWithoutOvercounting()
        throws
    {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 40_000)
        let rootURL = fixture.directory.appendingPathComponent("root.jsonl")
        let childURL = fixture.directory.appendingPathComponent("child.jsonl")
        try writeRollout([
            try eventRecord(
                "task_started",
                turnID: "root-turn",
                timestamp: now.addingTimeInterval(-8)),
        ], to: rootURL)
        try writeRollout([
            try eventRecord(
                "task_started",
                turnID: "child-turn",
                timestamp: now.addingTimeInterval(-4)),
            try commentaryRecord(
                "Child progress is aggregated safely",
                timestamp: now.addingTimeInterval(-2)),
        ], to: childURL)
        try fixture.insert(
            id: "root-thread",
            rolloutURL: rootURL,
            updatedAt: 39_992)
        try fixture.insert(
            id: "child-thread",
            rolloutURL: childURL,
            updatedAt: 39_998,
            threadSource: "subagent",
            source: """
            {"subagent":{"thread_spawn":{"parent_thread_id":"root-thread","depth":1}}}
            """)

        let snapshot = makeDetector(fixture).detectSnapshot(now: now)

        XCTAssertEqual(snapshot.activeSessionIDs, ["root-thread"])
        XCTAssertEqual(snapshot.sessionActivities.count, 1)
        XCTAssertEqual(
            snapshot.sessionActivities["root-thread"]?
                .progressLines.map(\.text),
            ["Child progress is aggregated safely"])
        XCTAssertEqual(
            snapshot.lastEventAt,
            Date(timeIntervalSince1970: 39_998))
    }

    func testCompletedSubagentIgnoresInheritedActiveParentTurn() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let childCreatedAt = Date(timeIntervalSince1970: 1_785_716_549.613)
        let now = childCreatedAt.addingTimeInterval(30)
        let childURL = fixture.directory.appendingPathComponent("child.jsonl")
        try writeRollout([
            try rootRecord(
                type: "session_meta",
                payload: [
                    "id": "child-thread",
                    "session_id": "root-thread",
                ],
                timestamp: childCreatedAt),
            try rootRecord(
                type: "session_meta",
                payload: [
                    "id": "ancestor-thread",
                    "session_id": "ancestor-thread",
                ],
                timestamp: childCreatedAt),
            try eventRecord(
                "task_started",
                turnID: "019fc4ff-024c-74f2-94e1-ee02fe3df06c",
                // `started_at` has only second precision. Keep this inside the
                // legacy tolerance to verify that UUIDv7 time wins.
                timestamp: childCreatedAt.addingTimeInterval(-0.5)),
            try eventRecord(
                "task_started",
                turnID: "019fc500-289c-7c40-9e98-64dda88b3229",
                timestamp: childCreatedAt.addingTimeInterval(0.179)),
            try eventRecord(
                "task_complete",
                turnID: "019fc500-289c-7c40-9e98-64dda88b3229",
                timestamp: now.addingTimeInterval(-1)),
        ], to: childURL)
        try fixture.insert(
            id: "child-thread",
            rolloutURL: childURL,
            createdAt: Int64(childCreatedAt.timeIntervalSince1970),
            updatedAt: Int64(now.timeIntervalSince1970 - 1),
            threadSource: "subagent",
            source: """
            {"subagent":{"thread_spawn":{"parent_thread_id":"root-thread","depth":1}}}
            """)

        let snapshot = makeDetector(fixture).detectSnapshot(now: now)

        XCTAssertTrue(snapshot.activeSessionIDs.isEmpty)
        XCTAssertTrue(snapshot.sessionActivities.isEmpty)
    }

    func testRepresentativeRolloutsAcrossThirtyEightCLIVersionFamilies()
        throws
    {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let versions = [
            "0.57.0", "0.58.0", "0.59.0", "0.60.0", "0.61.0",
            "0.62.0", "0.63.0", "0.64.0", "0.65.0", "0.66.0",
            "0.67.0", "0.68.0", "0.69.0", "0.70.0", "0.71.0",
            "0.72.0", "0.73.0", "0.74.0", "0.75.0", "0.76.0",
            "0.77.0", "0.78.0", "0.79.0", "0.80.0", "0.81.0",
            "0.82.0", "0.83.0", "0.84.0", "0.85.0", "0.86.0",
            "0.90.0", "0.100.0", "0.110.0", "0.120.0", "0.130.0",
            "0.140.0", "0.145.0-alpha.4", "0.146.0-alpha.3",
        ]
        XCTAssertEqual(versions.count, 38)
        let now = Date(timeIntervalSince1970: 50_000)

        for (index, version) in versions.enumerated() {
            let id = "version-thread-\(index)"
            let rolloutURL = fixture.directory
                .appendingPathComponent("version-\(index).jsonl")
            try writeRollout([
                try rootRecord(
                    type: "session_meta",
                    payload: [
                        "id": id,
                        "cli_version": version,
                    ],
                    timestamp: now.addingTimeInterval(-6)),
                try eventRecord(
                    "task_started",
                    turnID: "turn-\(index)",
                    timestamp: now.addingTimeInterval(-5)),
                // Unknown records are deliberately interspersed. Version
                // drift must fail closed without erasing known lifecycle.
                try eventRecord(
                    "future_event_family_\(index)",
                    turnID: "turn-\(index)",
                    timestamp: now.addingTimeInterval(-4)),
                try commentaryRecord(
                    "Compatible progress family \(index)",
                    timestamp: now.addingTimeInterval(-3)),
            ], to: rolloutURL)
            try fixture.insert(
                id: id,
                rolloutURL: rolloutURL,
                updatedAt: 49_999 - Int64(index))
        }

        let snapshot = CodexLocalActivityDetector(
            stateDatabaseURL: fixture.databaseURL,
            recentActivityWindow: 3_600,
            candidateLimit: 64,
            maximumRolloutScanBytes: 2 * 1_024 * 1_024,
            rolloutReadChunkBytes: 47
        ).detectSnapshot(now: now)

        XCTAssertEqual(snapshot.activeSessionIDs.count, versions.count)
        XCTAssertEqual(snapshot.sessionActivities.count, versions.count)
        for index in versions.indices {
            XCTAssertEqual(
                snapshot.sessionActivities["version-thread-\(index)"]?
                    .progressLines.map(\.text),
                ["Compatible progress family \(index)"])
        }
    }

    func testProgressTextDropsHostileRecordsInsteadOfPartiallyRedacting()
        throws
    {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 60_000)
        let rolloutURL = fixture.directory
            .appendingPathComponent("hostile.jsonl")
        let hostile = [
            "Bearer LAN_SECRET_SENTINEL",
            "sk-API_KEY_SENTINEL_1234567890",
            "api_key = CREDENTIAL_SENTINEL",
            "private@example.com finished",
            "/Users/private/workspace/secret.txt updated",
            "~/workspace/private updated",
            "https://example.test/path?token=QUERY_SECRET_SENTINEL",
            "session_id=SESSION-ID-SENTINEL",
            "turn-id: TURN-ID-SENTINEL",
            "agent_id=AGENT-ID-SENTINEL",
            "550e8400-e29b-41d4-a716-446655440000",
        ]
        var records = [try eventRecord(
            "task_started",
            turnID: "hostile-turn",
            timestamp: now.addingTimeInterval(-20))]
        for (index, text) in hostile.enumerated() {
            records.append(try commentaryRecord(
                text,
                timestamp: now.addingTimeInterval(
                    TimeInterval(-18 + index))))
        }
        records.append(try responseItemRecord(
            type: "function_call_output",
            fields: [
                "call_id": "call-secret-output",
                "output": "TERMINAL_RAW_SENTINEL safe-looking text",
            ],
            timestamp: now.addingTimeInterval(-4)))
        records.append(try commentaryRecord(
            "Safe progress survived",
            timestamp: now.addingTimeInterval(-2)))
        records.append(try commentaryRecord(
            "\u{001B}[31mA safe\u{001B}[0m\u{0007}   update",
            timestamp: now.addingTimeInterval(-1)))
        try writeRollout(records, to: rolloutURL)
        try fixture.insert(
            id: "hostile-thread",
            rolloutURL: rolloutURL,
            updatedAt: 59_999)

        let activity = makeDetector(fixture).detectSnapshot(now: now)
            .sessionActivities["hostile-thread"]
        let lines = try XCTUnwrap(activity?.progressLines.map(\.text))
        let encoded = lines.joined(separator: "|")

        XCTAssertEqual(
            lines,
            ["Safe progress survived", "A safe update"])
        for sentinel in hostile + ["TERMINAL_RAW_SENTINEL"] {
            XCTAssertFalse(encoded.contains(sentinel), sentinel)
        }
        XCTAssertLessThanOrEqual(lines.count, 2)
        for line in lines {
            XCTAssertLessThanOrEqual(line.count, 120)
            XCTAssertLessThanOrEqual(line.utf8.count, 512)
        }
    }

    func testToolAdapterExposesOnlyAllowlistedSemanticValues() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 70_000)
        let rolloutURL = fixture.directory
            .appendingPathComponent("tool.jsonl")
        try writeRollout([
            try eventRecord(
                "task_started",
                turnID: "tool-turn",
                timestamp: now.addingTimeInterval(-5)),
            try responseItemRecord(
                type: "function_call",
                fields: [
                    "call_id": "call-private-id",
                    "name": "apply_patch",
                    "arguments":
                        "Bearer ARGUMENT_SECRET /Users/private/file",
                ],
                timestamp: now.addingTimeInterval(-2)),
        ], to: rolloutURL)
        try fixture.insert(
            id: "tool-thread",
            rolloutURL: rolloutURL,
            updatedAt: 69_999)
        let detector = makeDetector(fixture)

        let inProgress = try XCTUnwrap(
            detector.detectSnapshot(now: now)
                .sessionActivities["tool-thread"])
        XCTAssertEqual(inProgress.semantic?.phase, .editing)
        XCTAssertEqual(inProgress.semantic?.toolCategory, .fileEdit)
        XCTAssertEqual(inProgress.semantic?.toolStatus, .inProgress)
        XCTAssertTrue(inProgress.progressLines.isEmpty)

        try append(
            Data((try responseItemRecord(
                type: "function_call_output",
                fields: [
                    "call_id": "call-private-id",
                    "output": "Bearer RESULT_SECRET",
                ],
                timestamp: now) + "\n").utf8),
            to: rolloutURL)
        let completed = try XCTUnwrap(
            detector.detectSnapshot(now: now)
                .sessionActivities["tool-thread"])
        XCTAssertEqual(completed.semantic?.phase, .editing)
        XCTAssertEqual(completed.semantic?.toolCategory, .fileEdit)
        XCTAssertEqual(completed.semantic?.toolStatus, .completed)
        XCTAssertTrue(completed.progressLines.isEmpty)
    }

    private func event(_ type: String) -> String {
        """
        {"timestamp":"2026-07-29T10:00:00Z","type":"event_msg","payload":{"type":"\(type)"}}
        """
    }

    private func makeDetector(
        _ fixture: SQLiteFixture
    ) -> CodexLocalActivityDetector {
        CodexLocalActivityDetector(
            stateDatabaseURL: fixture.databaseURL,
            recentActivityWindow: 3_600,
            candidateLimit: 64,
            maximumRolloutScanBytes: 512 * 1_024,
            rolloutReadChunkBytes: 53)
    }

    private func writeRollout(
        _ records: [String],
        to url: URL,
        atomically: Bool = false
    ) throws {
        try Data((records.joined(separator: "\n") + "\n").utf8)
            .write(to: url, options: atomically ? .atomic : [])
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func eventRecord(
        _ eventType: String,
        turnID: String,
        timestamp: Date
    ) throws -> String {
        try rootRecord(
            type: "event_msg",
            payload: [
                "type": eventType,
                "turn_id": turnID,
                "started_at": timestamp.timeIntervalSince1970,
            ],
            timestamp: timestamp)
    }

    private func commentaryRecord(
        _ text: String,
        timestamp: Date
    ) throws -> String {
        try responseItemRecord(
            type: "message",
            fields: [
                "role": "assistant",
                "phase": "commentary",
                "content": [
                    [
                        "type": "output_text",
                        "text": text,
                    ],
                ],
            ],
            timestamp: timestamp)
    }

    private func responseItemRecord(
        type: String,
        fields: [String: Any],
        timestamp: Date
    ) throws -> String {
        var payload = fields
        payload["type"] = type
        return try rootRecord(
            type: "response_item",
            payload: payload,
            timestamp: timestamp)
    }

    private func rootRecord(
        type: String,
        payload: [String: Any],
        timestamp: Date
    ) throws -> String {
        let object: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: timestamp),
            "type": type,
            "payload": payload,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func rollout(
        _ lines: [String],
        repeatingMiddleLine: Int = 0
    ) -> String {
        guard repeatingMiddleLine > 0, lines.count >= 2 else {
            return lines.joined(separator: "\n") + "\n"
        }
        var expanded = [lines[0]]
        expanded.append(
            contentsOf: Array(
                repeating: lines[1],
                count: repeatingMiddleLine
            )
        )
        expanded.append(contentsOf: lines.dropFirst(2))
        return expanded.joined(separator: "\n") + "\n"
    }

    private func makeFixture() throws -> SQLiteFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CodexLocalActivityDetectorTests.\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return try SQLiteFixture(directory: directory)
    }
}

private final class SQLiteFixture {
    let directory: URL
    let databaseURL: URL
    private var database: OpaquePointer?

    init(directory: URL) throws {
        self.directory = directory
        databaseURL = directory.appendingPathComponent("state_5.sqlite")
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK,
              let database else {
            throw NSError(
                domain: "CodexLocalActivityDetectorTests",
                code: 1
            )
        }
        try execute(
            """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT NOT NULL,
                created_at INTEGER,
                updated_at INTEGER NOT NULL,
                thread_source TEXT,
                source TEXT,
                title TEXT,
                cwd TEXT,
                model TEXT,
                reasoning_effort TEXT,
                model_provider TEXT,
                sandbox_policy TEXT,
                approval_mode TEXT,
                tokens_used INTEGER,
                git_branch TEXT,
                cli_version TEXT,
                agent_nickname TEXT,
                archived INTEGER NOT NULL DEFAULT 0
            );
            """,
            database: database
        )
    }

    func insert(
        id: String,
        rolloutURL: URL,
        createdAt: Int64? = nil,
        updatedAt: Int64,
        threadSource: String? = nil,
        source: String? = nil,
        title: String? = nil,
        cwd: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        modelProvider: String? = nil,
        sandboxPolicy: String? = nil,
        approvalMode: String? = nil,
        tokensUsed: Int64? = nil,
        gitBranch: String? = nil,
        cliVersion: String? = nil,
        agentNickname: String? = nil
    ) throws {
        guard let database else {
            throw NSError(
                domain: "CodexLocalActivityDetectorTests",
                code: 2
            )
        }
        let sql = """
        INSERT INTO threads (
            id, rollout_path, created_at, updated_at, thread_source, source,
            title, cwd, model, reasoning_effort, model_provider,
            sandbox_policy, approval_mode, tokens_used, git_branch,
            cli_version, agent_nickname, archived
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            sql,
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw NSError(
                domain: "CodexLocalActivityDetectorTests",
                code: 3
            )
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(
            -1,
            to: sqlite3_destructor_type.self
        )
        sqlite3_bind_text(statement, 1, id, -1, transient)
        sqlite3_bind_text(
            statement,
            2,
            rolloutURL.path,
            -1,
            transient
        )
        sqlite3_bind_int64(
            statement,
            3,
            createdAt ?? updatedAt - 3_600)
        sqlite3_bind_int64(statement, 4, updatedAt)
        if let threadSource {
            sqlite3_bind_text(statement, 5, threadSource, -1, transient)
        } else {
            sqlite3_bind_null(statement, 5)
        }
        if let source {
            sqlite3_bind_text(statement, 6, source, -1, transient)
        } else {
            sqlite3_bind_null(statement, 6)
        }
        for (index, value) in [
            title,
            cwd,
            model,
            reasoningEffort,
            modelProvider,
            sandboxPolicy,
            approvalMode,
        ].enumerated() {
            let binding = Int32(index + 7)
            if let value {
                sqlite3_bind_text(statement, binding, value, -1, transient)
            } else {
                sqlite3_bind_null(statement, binding)
            }
        }
        if let tokensUsed {
            sqlite3_bind_int64(statement, 14, tokensUsed)
        } else {
            sqlite3_bind_null(statement, 14)
        }
        for (index, value) in [
            gitBranch,
            cliVersion,
            agentNickname,
        ].enumerated() {
            let binding = Int32(index + 15)
            if let value {
                sqlite3_bind_text(statement, binding, value, -1, transient)
            } else {
                sqlite3_bind_null(statement, binding)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(
                domain: "CodexLocalActivityDetectorTests",
                code: 4
            )
        }
    }

    func cleanup() {
        if let database {
            sqlite3_close(database)
            self.database = nil
        }
        try? FileManager.default.removeItem(at: directory)
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    private func execute(
        _ sql: String,
        database: OpaquePointer
    ) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(
                domain: "CodexLocalActivityDetectorTests",
                code: 5
            )
        }
    }
}
