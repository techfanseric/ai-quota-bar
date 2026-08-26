import Foundation
import Network
import XCTest
@testable import AIQuotaBar

final class MobileDashboardSecurityTests: XCTestCase {
    func testLocalHostNameValidationAcceptsBonjourLabelOnly() {
        XCTAssertEqual(
            MobileDashboardNetworkAddress.normalizedLocalHostName(
                " Studio-Mac "),
            "studio-mac")
        XCTAssertEqual(
            MobileDashboardNetworkAddress.normalizedLocalHostName(
                "Studio-Mac.local."),
            "studio-mac")

        let invalidNames: [String?] = [
            nil,
            "",
            "-studio",
            "studio-",
            "studio.example",
            "studio/local",
            "studio#token=attacker",
            "stúdio",
            String(repeating: "a", count: 64),
        ]
        for name in invalidNames {
            XCTAssertNil(
                MobileDashboardNetworkAddress
                    .normalizedLocalHostName(name),
                name ?? "nil")
        }
    }

    func testBonjourAccessLinkIsPrimaryAndPrivateIPsAreFallbacks()
        throws
    {
        let links = MobileDashboardAccessLinkBuilder.make(
            localHostName: "Studio-Mac",
            ipv4Addresses: [
                "192.168.1.7",
                "10.0.0.4",
                "192.168.1.7",
                "203.0.113.10",
            ],
            port: 18_765)

        let primary = try XCTUnwrap(links.primary)
        let components = try XCTUnwrap(
            URLComponents(string: primary))
        XCTAssertEqual(components.scheme, "http")
        XCTAssertEqual(components.host, "studio-mac.local")
        XCTAssertEqual(components.port, 18_765)
        XCTAssertEqual(components.path, "/")
        XCTAssertNil(components.fragment)
        XCTAssertEqual(
            links.alternates.compactMap {
                URL(string: $0)?.host
            },
            ["192.168.1.7", "10.0.0.4"])
    }

    func testInvalidLocalHostNameFallsBackToPrivateIPAddress()
        throws
    {
        let links = MobileDashboardAccessLinkBuilder.make(
            localHostName: "bad/name",
            ipv4Addresses: ["192.168.1.20", "172.16.0.2"],
            port: 18_765)

        let primary = try XCTUnwrap(links.primary)
        let components = try XCTUnwrap(
            URLComponents(string: primary))
        XCTAssertEqual(components.host, "192.168.1.20")
        XCTAssertNil(components.fragment)
        XCTAssertEqual(links.alternates.count, 1)

        XCTAssertNil(
            MobileDashboardAccessLinkBuilder.make(
                localHostName: nil,
                ipv4Addresses: ["203.0.113.20"],
                port: 18_765).primary)
    }

    func testAccountNamesAreMaskedByDefault() {
        XCTAssertEqual(
            MobileDashboardAccountPrivacy.displayName(
                "alice@example.com",
                masksAccountNames: true),
            "a•••@example.com")
        XCTAssertEqual(
            MobileDashboardAccountPrivacy.displayName(
                "Personal account",
                masksAccountNames: true),
            "Pe•••")
        XCTAssertEqual(
            MobileDashboardAccountPrivacy.displayName(
                "AI",
                masksAccountNames: true),
            "A•••")
        XCTAssertEqual(
            MobileDashboardAccountPrivacy.displayName(
                "A",
                masksAccountNames: true),
            "•••")
        XCTAssertEqual(
            MobileDashboardAccountPrivacy.displayName(
                "a@example.com",
                masksAccountNames: true),
            "•••@example.com")
        XCTAssertEqual(
            MobileDashboardAccountPrivacy.displayName(
                "账号甲",
                masksAccountNames: true),
            "账号•••")
        XCTAssertEqual(
            MobileDashboardAccountPrivacy.displayName(
                "🧑🏽‍💻用户",
                masksAccountNames: true),
            "🧑🏽‍💻用•••")
        XCTAssertNil(
            MobileDashboardAccountPrivacy.displayName(
                nil,
                masksAccountNames: true))
        XCTAssertNil(
            MobileDashboardAccountPrivacy.displayName(
                " \n\t ",
                masksAccountNames: true))
    }

    func testAccountNameMaskCanBeExplicitlyDisabled() {
        XCTAssertEqual(
            MobileDashboardAccountPrivacy.displayName(
                "alice@example.com",
                masksAccountNames: false),
            "alice@example.com")
        XCTAssertEqual(
            MobileDashboardAccountPrivacy.displayName(
                "  帐号甲  ",
                masksAccountNames: false),
            "  帐号甲  ",
            "Disabling masking must preserve the original value exactly.")
    }

    func testEncodedMobileModelCannotLeakRawAccountThroughIdentifier()
        throws
    {
        let rawAccount = "alice@example.com"
        let maskedAccount = try XCTUnwrap(
            MobileDashboardAccountPrivacy.displayName(
                rawAccount,
                masksAccountNames: true))
        let model = MobileModelQuotaSnapshot(
            displayOrder: 0,
            isPrimary: true,
            accountName: maskedAccount,
            modelName: "Codex",
            plan: "Plus",
            source: "local",
            detail: nil,
            remainingText: "50%",
            remainingPercent: 50,
            total: 100,
            remaining: 50,
            startsAt: nil,
            resetsAt: nil,
            resetText: "later",
            isShortWindow: false,
            isExhausted: false,
            isFull: false,
            isCurrentIntervalPercentMode: true,
            usesReverseProgressTint: false,
            rendersAreaChart: true,
            hasCurrentIntervalPace: false,
            paceStage: nil,
            paceGuideTone: nil,
            paceGuideExpectedUsedPercent: nil,
            paceGuideExpectedRemaining: nil,
            paceGuideShowsMarker: false,
            weeklyTotal: 0,
            weeklyRemaining: 0,
            weeklyRemainingPercent: nil,
            weeklyUnlimited: true,
            paceDeltaPercent: nil,
            sampledAt: nil,
            samples: [],
            consumptionForecasts: [],
            cycles: [])

        let data = try JSONEncoder().encode(model)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any])

        XCTAssertEqual(
            object["accountName"] as? String,
            maskedAccount)
        XCTAssertEqual(object["displayOrder"] as? Int, 0)
        XCTAssertEqual(object["isPrimary"] as? Bool, true)
        XCTAssertNil(
            object["id"],
            "The source model identifier embeds the raw account name.")
        XCTAssertEqual(
            object["isCurrentIntervalPercentMode"] as? Bool,
            true)
        XCTAssertEqual(
            object["usesReverseProgressTint"] as? Bool,
            false)
        XCTAssertEqual(object["rendersAreaChart"] as? Bool, true)
        XCTAssertEqual(
            object["hasCurrentIntervalPace"] as? Bool,
            false)
        XCTAssertEqual(
            object["paceGuideShowsMarker"] as? Bool,
            false)
        XCTAssertFalse(
            String(decoding: data, as: UTF8.self)
                .contains(rawAccount))
    }

    func testEventEnvelopeEncodesActivityBackgroundEffectAsAllowlistedValue()
        throws
    {
        let envelope = MobileDashboardEventEnvelope(
            oledProtectionEnabled: true,
            experimentalWakeMediaEnabled: false,
            activityBackgroundEffect: .taskTelemetryMarquee,
            taskTelemetryFields: [.title, .tool],
            colorScheme: .dark,
            idleBlackoutMarqueeEnabled: true,
            snapshot: snapshot(
                generatedAt: Date(timeIntervalSince1970: 100),
                connectivity: "online"))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(envelope))
                as? [String: Any])

        XCTAssertEqual(
            object["activityBackgroundEffect"] as? String,
            "taskTelemetryMarquee")
        XCTAssertEqual(
            object["taskTelemetryFields"] as? [String],
            ["title", "tool"])
        XCTAssertEqual(object["colorScheme"] as? String, "dark")
        XCTAssertEqual(
            object["idleBlackoutMarqueeEnabled"] as? Bool,
            true)
        XCTAssertEqual(
            Set(object.keys),
            Set([
                "oledProtectionEnabled",
                "experimentalWakeMediaEnabled",
                "activityBackgroundEffect",
                "taskTelemetryFields",
                "colorScheme",
                "idleBlackoutMarqueeEnabled",
                "snapshot",
            ]),
            "The SSE envelope exposes the idle policy as one top-level flag.")
    }

    func testIdleBlackoutFlagDoesNotRewriteStaleOrUnavailableActivity()
        throws
    {
        for state in ["stale", "unavailable"] {
            let activity = MobileActivitySummarySnapshot(
                state: state,
                activeTaskCount: 0,
                oldestStartedAt: nil,
                elapsedSeconds: nil,
                lastActivityAt: nil,
                phase: "unknown",
                toolCategory: nil,
                toolStatus: nil,
                progressLines: nil,
                recentEvents: [])
            let envelope = MobileDashboardEventEnvelope(
                oledProtectionEnabled: true,
                experimentalWakeMediaEnabled: false,
                activityBackgroundEffect: .grainyDigitalRain,
                colorScheme: .dark,
                idleBlackoutMarqueeEnabled: true,
                snapshot: snapshot(
                    generatedAt: Date(timeIntervalSince1970: 100),
                    connectivity: "online",
                    activitySummary: activity))
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(envelope))
                    as? [String: Any])
            let snapshotObject = try XCTUnwrap(
                object["snapshot"] as? [String: Any])
            let activityObject = try XCTUnwrap(
                snapshotObject["activitySummary"] as? [String: Any])

            XCTAssertEqual(
                object["idleBlackoutMarqueeEnabled"] as? Bool,
                true)
            XCTAssertEqual(
                activityObject["state"] as? String,
                state,
                "Blackout eligibility is a client display policy only.")
        }
    }

    @MainActor
    func testActivitySummaryAndSSEEnvelopeOmitHostileHookIdentifiersAndText()
        throws
    {
        let suiteName = "MobileDashboardSecurityTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: ClosedLidModeManager.enabledKey)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let missingHelper = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let coordinator = CodexSleepProtectionCoordinator(
            defaults: defaults,
            hookInstaller: CodexHookInstaller(
                hooksURL: missingHelper.appendingPathComponent("hooks.json"),
                helperURL: missingHelper.appendingPathComponent("helper")),
            localActivityProvider: nil,
            closedLidModeManager: ClosedLidModeManager(
                defaults: defaults,
                bundle: .main))
        coordinator.start()
        defer { coordinator.stop() }

        let sentinels = [
            "TERMINAL_RAW_SENTINEL",
            "Bearer SSE_SECRET_SENTINEL",
            "sk-API_KEY_SENTINEL",
            "private@example.com",
            "/Users/private/workspace/secret.txt",
            "~/workspace/private",
            "https://example.test/path?token=QUERY_SECRET_SENTINEL",
            "session-ID-SENTINEL",
            "turn-ID-SENTINEL",
            "agent-ID-SENTINEL",
        ]
        let now = Date()
        coordinator.receive(CodexHookEvent(
            name: .userPromptSubmit,
            sessionID: sentinels.joined(separator: "|"),
            turnID: "turn-ID-SENTINEL",
            agentID: nil,
            date: now.addingTimeInterval(-2)))
        coordinator.receive(CodexHookEvent(
            name: .subagentStart,
            sessionID: sentinels.joined(separator: "|"),
            turnID: "turn-ID-SENTINEL",
            agentID: "agent-ID-SENTINEL",
            date: now.addingTimeInterval(-1)))

        let activity = MobileDashboardSnapshotBuilder.activitySummary(
            coordinator,
            now: now)
        let envelope = MobileDashboardEventEnvelope(
            oledProtectionEnabled: true,
            experimentalWakeMediaEnabled: false,
            activityBackgroundEffect: .dotWaves,
            colorScheme: .light,
            idleBlackoutMarqueeEnabled: true,
            snapshot: snapshot(
                generatedAt: now,
                connectivity: "online",
                activitySummary: activity))
        let data = try JSONEncoder().encode(envelope)
        let encoded = String(decoding: data, as: UTF8.self)

        for sentinel in sentinels {
            XCTAssertFalse(encoded.contains(sentinel), sentinel)
        }
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let snapshotObject = try XCTUnwrap(
            object["snapshot"] as? [String: Any])
        let activityObject = try XCTUnwrap(
            snapshotObject["activitySummary"] as? [String: Any])
        XCTAssertEqual(
            Set(activityObject.keys),
            Set([
                "state",
                "activeTaskCount",
                "oldestStartedAt",
                "elapsedSeconds",
                "lastActivityAt",
                "phase",
                "toolCategory",
                "toolStatus",
                "recentEvents",
                "tasks",
            ]))
        XCTAssertEqual(activityObject["activeTaskCount"] as? Int, 1)
        XCTAssertEqual(activityObject["state"] as? String, "working")
        XCTAssertEqual(activityObject["phase"] as? String, "delegating")
        XCTAssertEqual(
            activityObject["toolCategory"] as? String,
            "subagent")
        XCTAssertEqual(
            activityObject["toolStatus"] as? String,
            "inProgress")
        XCTAssertNil(activityObject["progressLines"])
    }

    @MainActor
    func testProgressLinesAreStructurallyOmittedUntilExplicitlyShared()
        throws
    {
        let suiteName = "MobileDashboardProgressGateTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: ClosedLidModeManager.enabledKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let missingHelper = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let coordinator = CodexSleepProtectionCoordinator(
            defaults: defaults,
            hookInstaller: CodexHookInstaller(
                hooksURL: missingHelper.appendingPathComponent("hooks.json"),
                helperURL: missingHelper.appendingPathComponent("helper")),
            localActivityProvider: nil,
            closedLidModeManager: ClosedLidModeManager(
                defaults: defaults,
                bundle: .main))
        coordinator.start()
        defer { coordinator.stop() }

        let now = Date(timeIntervalSince1970: 80_000)
        coordinator.receiveLocalSnapshot(CodexLocalActivitySnapshot(
            activeSessionIDs: ["private-session-id"],
            lastEventAt: now,
            sessionActivities: [
                "private-session-id": CodexLocalSessionActivity(
                    title: "Safe paired task title",
                    projectName: "ai-quota-bar",
                    gitBranch: "codex/task-barrage",
                    source: "vscode / user",
                    model: "gpt-5.6-sol",
                    modelProvider: "openai",
                    reasoningEffort: "xhigh",
                    sandboxPolicy: "danger-full-access",
                    approvalMode: "never",
                    tokensUsed: 12_345,
                    activeSubtaskCount: 2,
                    subtaskNames: ["Curie", "Turing"],
                    createdAt: now.addingTimeInterval(-120),
                    startedAt: now.addingTimeInterval(-20),
                    lastEventAt: now,
                    cliVersion: "1.2.3",
                    semantic: CodexSafeActivitySemantic(
                        phase: .testing,
                        toolCategory: .shell,
                        toolStatus: .inProgress,
                        at: now),
                    progressLines: [
                        CodexSafeProgressLine(
                            text: "Safe paired progress line",
                            at: now),
                    ],
                    recentEvents: []),
            ]))

        let hidden = MobileDashboardSnapshotBuilder.activitySummary(
            coordinator,
            now: now,
            sharesTaskProgressText: false)
        let shown = MobileDashboardSnapshotBuilder.activitySummary(
            coordinator,
            now: now,
            sharesTaskProgressText: true)
        let hiddenObject = try activityObject(hidden)
        let shownObject = try activityObject(shown)

        XCTAssertEqual(hiddenObject["phase"] as? String, "testing")
        XCTAssertEqual(hiddenObject["toolCategory"] as? String, "shell")
        XCTAssertEqual(hiddenObject["toolStatus"] as? String, "inProgress")
        XCTAssertNil(
            hiddenObject["progressLines"],
            "The key itself must be absent while sharing is disabled.")
        XCTAssertEqual(
            shownObject["progressLines"] as? [String],
            ["Safe paired progress line"])
        XCTAssertNil(shownObject["private-session-id"])
        let hiddenTasks = try XCTUnwrap(
            hiddenObject["tasks"] as? [[String: Any]])
        let shownTasks = try XCTUnwrap(
            shownObject["tasks"] as? [[String: Any]])
        let hiddenTask = try XCTUnwrap(hiddenTasks.first)
        let shownTask = try XCTUnwrap(shownTasks.first)
        XCTAssertNil(hiddenTask["title"])
        XCTAssertNil(hiddenTask["projectName"])
        XCTAssertNil(hiddenTask["gitBranch"])
        XCTAssertNil(hiddenTask["subtaskNames"])
        XCTAssertNil(hiddenTask["progressLines"])
        XCTAssertEqual(hiddenTask["source"] as? String, "vscode / user")
        XCTAssertEqual(hiddenTask["model"] as? String, "gpt-5.6-sol")
        XCTAssertEqual(hiddenTask["modelProvider"] as? String, "openai")
        XCTAssertEqual(hiddenTask["reasoningEffort"] as? String, "xhigh")
        XCTAssertEqual(
            hiddenTask["sandboxPolicy"] as? String,
            "danger-full-access")
        XCTAssertEqual(hiddenTask["approvalMode"] as? String, "never")
        XCTAssertEqual(hiddenTask["tokensUsed"] as? Int, 12_345)
        XCTAssertEqual(hiddenTask["cliVersion"] as? String, "1.2.3")
        XCTAssertEqual(hiddenTask["activeSubtaskCount"] as? Int, 2)
        XCTAssertEqual(shownTask["title"] as? String, "Safe paired task title")
        XCTAssertEqual(shownTask["projectName"] as? String, "ai-quota-bar")
        XCTAssertEqual(shownTask["gitBranch"] as? String, "codex/task-barrage")
        XCTAssertEqual(
            shownTask["subtaskNames"] as? [String],
            ["Curie", "Turing"])
        XCTAssertEqual(
            shownTask["progressLines"] as? [String],
            ["Safe paired progress line"])

        coordinator.receiveLocalSnapshot(.empty)
        let idleSharedObject = try activityObject(
            MobileDashboardSnapshotBuilder.activitySummary(
                coordinator,
                now: now,
                sharesTaskProgressText: true))
        XCTAssertEqual(
            idleSharedObject["progressLines"] as? [String],
            [],
            "An enabled share serializes an empty array while idle.")
    }

    func testQuotaSampleKeepsRawRemainingAndCompatiblePercent() throws {
        let sample = MobileQuotaSampleSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_000),
            remaining: 42,
            remainingPercent: 84)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(sample))
                as? [String: Any])

        XCTAssertEqual(object["remaining"] as? Int, 42)
        XCTAssertEqual(object["remainingPercent"] as? Double, 84)
    }

    func testEncodedConnectionOmitsInternalProcessPathAndIdentifier()
        throws
    {
        let connection = MobileActiveConnectionSnapshot(
            host: "api.openai.com",
            network: "tcp",
            route: "Trusted route",
            duration: 42,
            uploadBytesPerSecond: 10,
            downloadBytesPerSecond: 20)
        let data = try JSONEncoder().encode(connection)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any])

        XCTAssertEqual(
            Set(object.keys),
            [
                "host",
                "network",
                "route",
                "duration",
                "uploadBytesPerSecond",
                "downloadBytesPerSecond",
            ])
        XCTAssertNil(object["id"])
        XCTAssertNil(object["process"])
        XCTAssertNil(object["processPath"])
        XCTAssertFalse(
            String(decoding: data, as: UTF8.self)
                .contains("/Applications/"))
    }

    func testMobileErrorCopyDoesNotExposeAssociatedRawText() {
        let sentinel =
            "/Users/private/Library/secret.json Bearer raw-token"
        let errors: [UsageError] = [
            .networkError(
                MobileDashboardSensitiveTestError(message: sentinel)),
            .apiError(sentinel),
        ]

        for language in AppLanguage.allCases {
            for error in errors {
                let description = MobileDashboardSafeText
                    .usageErrorDescription(
                        error,
                        language: language)
                XCTAssertFalse(description.contains("/Users/"))
                XCTAssertFalse(description.contains("raw-token"))
                XCTAssertFalse(description.contains("Bearer"))
                XCTAssertFalse(description.isEmpty)
            }
            XCTAssertFalse(
                MobileDashboardSafeText
                    .cloudUsageError(language: language)
                    .isEmpty)
        }
    }

    func testBearerTokenComparisonRequiresExactValue() {
        let token = "xnRZaW8xnRZaW8xnRZaW8xnRZaW8"

        XCTAssertTrue(
            MobileDashboardHTTPServer.constantTimeEqual(
                token,
                token))
        XCTAssertFalse(
            MobileDashboardHTTPServer.constantTimeEqual(
                token,
                token + "A"))
        XCTAssertFalse(
            MobileDashboardHTTPServer.constantTimeEqual(
                token,
                String(token.dropLast()) + "B"))
        XCTAssertFalse(
            MobileDashboardHTTPServer.constantTimeEqual(
                "",
                token))
        XCTAssertFalse(
            MobileDashboardHTTPServer.constantTimeEqual(
                token,
                token + String(repeating: "\0", count: 256)),
            "Length differences must not truncate in the accumulator.")
    }

    func testHeaderParsingNormalizesNamesAndTrimsValues() {
        let headers = MobileDashboardHTTPServer.parseHeaders([
            "Authorization:   Bearer local-token  ",
            "X-Status: ready:live",
            "Malformed header",
            "  X-Spaced-Name  : value ",
        ])

        XCTAssertEqual(
            headers["authorization"],
            "Bearer local-token")
        XCTAssertEqual(headers["x-status"], "ready:live")
        XCTAssertEqual(headers["x-spaced-name"], "value")
        XCTAssertNil(headers["malformed header"])

        let ambiguous = MobileDashboardHTTPServer.parseHeaders([
            "Authorization: Bearer first",
            "Authorization: Bearer second",
            "Cookie: theme=black",
            "Cookie: mode=standalone",
        ])
        XCTAssertEqual(ambiguous["authorization"], "")
        XCTAssertEqual(
            ambiguous["cookie"],
            "theme=black; mode=standalone")

        let duplicateRange =
            MobileDashboardHTTPServer.parseHeaders([
                "Range: bytes=0-1",
                "Range: bytes=2-3",
            ])
        XCTAssertEqual(
            duplicateRange["range"],
            "",
            "Duplicate Range headers must not use last-header-wins semantics.")
    }

    func testSingleByteRangeParsingIsStrictAndBounded() {
        XCTAssertEqual(
            MobileDashboardHTTPServer.byteRange(
                from: "bytes=0-9",
                resourceLength: 100),
            0..<10)
        XCTAssertEqual(
            MobileDashboardHTTPServer.byteRange(
                from: "BYTES=0-9",
                resourceLength: 100),
            0..<10)
        XCTAssertEqual(
            MobileDashboardHTTPServer.byteRange(
                from: "bytes=90-",
                resourceLength: 100),
            90..<100)
        XCTAssertEqual(
            MobileDashboardHTTPServer.byteRange(
                from: "bytes=-10",
                resourceLength: 100),
            90..<100)
        XCTAssertEqual(
            MobileDashboardHTTPServer.byteRange(
                from: "bytes=-200",
                resourceLength: 100),
            0..<100)
        XCTAssertEqual(
            MobileDashboardHTTPServer.byteRange(
                from: "bytes=95-999",
                resourceLength: 100),
            95..<100,
            "A valid oversized end position is bounded to the resource.")

        let invalidValues = [
            "bytes=",
            "bytes=-0",
            "bytes=100-",
            "bytes=10-9",
            "bytes=0-1,3-4",
            "bytes= 0-1",
            "bytes=+0-1",
            "items=0-1",
            "bytes=0--1",
            "bytes=0-18446744073709551616",
            "",
        ]
        for value in invalidValues {
            XCTAssertNil(
                MobileDashboardHTTPServer.byteRange(
                    from: value,
                    resourceLength: 100),
                value)
        }
        XCTAssertNil(
            MobileDashboardHTTPServer.byteRange(
                from: "bytes=0-0",
                resourceLength: 0))
    }

    func testPWAClaimRequiresAnExactSameOriginPOST() {
        XCTAssertTrue(
            MobileDashboardHTTPServer.isSameOriginPOST(
                headers: [
                    "host": "192.168.1.20:18765",
                    "origin": "http://192.168.1.20:18765",
                ]))
        XCTAssertTrue(
            MobileDashboardHTTPServer.isSameOriginPOST(
                headers: [
                    "host": "studio-mac.local:18765",
                    "origin": "http://studio-mac.local:18765",
                ]))
        XCTAssertTrue(
            MobileDashboardHTTPServer.isSameOriginPOST(
                headers: [
                    "host": "[::1]:18765",
                    "origin": "http://[::1]:18765",
                ]))
        XCTAssertFalse(
            MobileDashboardHTTPServer.isSameOriginPOST(
                headers: [
                    "host": "192.168.1.20:18765",
                    "origin": "http://192.168.1.20:18766",
                ]))
        XCTAssertFalse(
            MobileDashboardHTTPServer.isSameOriginPOST(
                headers: [
                    "host": "192.168.1.20:18765",
                    "origin": "http://192.168.1.21:18765",
                ]))
        XCTAssertFalse(
            MobileDashboardHTTPServer.isSameOriginPOST(
                headers: [
                    "host": "192.168.1.20:18765",
                    "origin": "null",
                ]))
        XCTAssertFalse(
            MobileDashboardHTTPServer.isSameOriginPOST(
                headers: [
                    "host": "192.168.1.20:18765",
                ]))
    }

    func testPWABootstrapCookieParsingRejectsDuplicatesAndOversizeValues() {
        let nonce = String(repeating: "A", count: 43)
        XCTAssertEqual(
            MobileDashboardHTTPServer.cookieValue(
                named:
                    MobileDashboardHTTPServer
                    .pwaBootstrapCookieName,
                in:
                    "theme=black; "
                    + "\(MobileDashboardHTTPServer.pwaBootstrapCookieName)=\(nonce); "
                    + "mode=standalone"),
            nonce)
        XCTAssertNil(
            MobileDashboardHTTPServer.cookieValue(
                named:
                    MobileDashboardHTTPServer
                    .pwaBootstrapCookieName,
                in:
                    "\(MobileDashboardHTTPServer.pwaBootstrapCookieName)=\(nonce); "
                    + "\(MobileDashboardHTTPServer.pwaBootstrapCookieName)=\(nonce)"),
            "Duplicate security cookies must be rejected.")
        XCTAssertNil(
            MobileDashboardHTTPServer.cookieValue(
                named:
                    MobileDashboardHTTPServer
                    .pwaBootstrapCookieName,
                in:
                    "\(MobileDashboardHTTPServer.pwaBootstrapCookieName)="
                    + String(repeating: "A", count: 257)))
        XCTAssertNil(
            MobileDashboardHTTPServer.cookieValue(
                named:
                    MobileDashboardHTTPServer
                    .pwaBootstrapCookieName,
                in: nil))
    }

    func testPWABootstrapNoncesAreStrongURLSafeValues() throws {
        let nonces = try (0..<32).map { _ in
            try XCTUnwrap(
                MobileDashboardHTTPServer
                    .generatePWABootstrapNonce())
        }

        XCTAssertEqual(Set(nonces).count, nonces.count)
        for nonce in nonces {
            XCTAssertTrue(
                MobileDashboardHTTPServer
                    .isValidPWABootstrapNonce(nonce))
            XCTAssertEqual(nonce.utf8.count, 43)
            XCTAssertFalse(nonce.contains("="))
            XCTAssertFalse(nonce.contains("+"))
            XCTAssertFalse(nonce.contains("/"))
        }
        XCTAssertFalse(
            MobileDashboardHTTPServer
                .isValidPWABootstrapNonce(
                    String(repeating: "A", count: 42)))
        XCTAssertFalse(
            MobileDashboardHTTPServer
                .isValidPWABootstrapNonce(
                    String(repeating: "A", count: 42) + "="))
    }

    func testPWAClaimBrokerIsOneTimeExpiringBoundedAndResetByRotation() {
        let first = String(repeating: "A", count: 43)
        let second = String(repeating: "B", count: 43)
        let third = String(repeating: "C", count: 43)
        let expiring = String(repeating: "D", count: 43)
        let rotated = String(repeating: "E", count: 43)
        let now = Date(timeIntervalSince1970: 1_000)
        let token = "test-only-access-token"
        var broker = MobileDashboardPWAClaimBroker(
            lifetime: 60,
            maximumOutstanding: 2)
        broker.reset(accessToken: token)

        XCTAssertTrue(broker.issue(nonce: first, now: now))
        XCTAssertTrue(
            broker.issue(
                nonce: second,
                now: now.addingTimeInterval(1)))
        XCTAssertTrue(
            broker.issue(
                nonce: third,
                now: now.addingTimeInterval(2)))
        XCTAssertEqual(broker.outstandingCount, 2)
        XCTAssertNil(
            broker.claim(
                nonce: first,
                now: now.addingTimeInterval(3)),
            "The oldest outstanding nonce must be evicted.")

        let claimed = broker.claim(
            nonce: second,
            now: now.addingTimeInterval(3))
        XCTAssertTrue(
            MobileDashboardHTTPServer.constantTimeEqual(
                claimed ?? "",
                token))
        XCTAssertNil(
            broker.claim(
                nonce: second,
                now: now.addingTimeInterval(3)),
            "A nonce must only be claimable once.")

        XCTAssertTrue(
            broker.issue(
                nonce: expiring,
                now: now.addingTimeInterval(10)))
        XCTAssertNil(
            broker.claim(
                nonce: expiring,
                now: now.addingTimeInterval(70)),
            "A nonce is invalid at its expiration boundary.")

        XCTAssertTrue(
            broker.issue(
                nonce: rotated,
                now: now.addingTimeInterval(80)))
        broker.reset(accessToken: "replacement-test-token")
        XCTAssertEqual(broker.outstandingCount, 0)
        XCTAssertNil(
            broker.claim(
                nonce: rotated,
                now: now.addingTimeInterval(81)),
            "Access-token rotation must revoke pending claims.")
    }

    func testManualPairingBrokerExpiresLocksAndAllowsBoundedRetry() {
        let now = Date(timeIntervalSince1970: 10_000)
        var broker = MobileDashboardManualPairingBroker()
        broker.reset(
            code: "12345678",
            expiresAt: now.addingTimeInterval(300))

        XCTAssertEqual(
            broker.claim(
                candidate: "12345678",
                peerID: "127.0.0.1",
                origin: "http://127.0.0.1:4000",
                now: now),
            .accepted)
        XCTAssertEqual(
            broker.claim(
                candidate: "12345678",
                peerID: "127.0.0.1",
                origin: "http://127.0.0.1:4000",
                now: now),
            .accepted)
        XCTAssertEqual(
            broker.claim(
                candidate: "12345678",
                peerID: "127.0.0.1",
                origin: "http://127.0.0.1:4000",
                now: now),
            .accepted)
        guard case .rateLimited = broker.claim(
            candidate: "12345678",
            peerID: "127.0.0.1",
            origin: "http://127.0.0.1:4000",
            now: now) else {
            return XCTFail("A fourth token disclosure must be rate limited.")
        }
        XCTAssertEqual(
            broker.claim(
                candidate: "12345678",
                peerID: "127.0.0.2",
                origin: "http://127.0.0.1:5000",
                now: now),
            .invalid,
            "The first successful client locks the current code.")

        broker.reset(
            code: "87654321",
            expiresAt: now.addingTimeInterval(1))
        XCTAssertEqual(
            broker.claim(
                candidate: "87654321",
                peerID: "127.0.0.1",
                origin: "http://127.0.0.1:4000",
                now: now.addingTimeInterval(1)),
            .invalid,
            "Expiry must use an exclusive upper bound.")
        broker.reset(code: nil, expiresAt: nil)
        XCTAssertEqual(
            broker.claim(
                candidate: "00000000",
                peerID: "127.0.0.1",
                origin: "http://127.0.0.1:4000",
                now: now),
            .unavailable)
    }

    func testManualPairingBrokerRateLimitsPeerAndOrigin() {
        let now = Date(timeIntervalSince1970: 20_000)
        var broker = MobileDashboardManualPairingBroker()
        broker.reset(
            code: "12345678",
            expiresAt: now.addingTimeInterval(600))

        for attempt in 1...5 {
            let result = broker.claim(
                candidate: "00000000",
                peerID: "127.0.0.1",
                origin: "http://127.0.0.1:\(4_000 + attempt)",
                now: now)
            if attempt < 5 {
                XCTAssertEqual(result, .invalid)
            } else if case let .rateLimited(retryAfter) = result {
                XCTAssertEqual(retryAfter, 300)
            } else {
                XCTFail("The fifth failed attempt must rate limit the peer.")
            }
        }
        guard case .rateLimited = broker.claim(
            candidate: "12345678",
            peerID: "127.0.0.1",
            origin: "http://127.0.0.1:9000",
            now: now) else {
            return XCTFail("A correct code cannot bypass a peer limit.")
        }
        XCTAssertEqual(
            broker.claim(
                candidate: "12345678",
                peerID: "127.0.0.1",
                origin: "http://127.0.0.1:9000",
                now: now.addingTimeInterval(300)),
            .accepted)
    }

    func testManualPairingBrokerHasGlobalBudgetAndBoundedTracking() {
        let now = Date(timeIntervalSince1970: 30_000)
        var broker = MobileDashboardManualPairingBroker()
        broker.reset(
            code: "12345678",
            expiresAt: now.addingTimeInterval(1_000))

        for attempt in 0..<MobileDashboardManualPairingBroker
            .maximumGlobalFailedAttempts {
            let result = broker.claim(
                candidate: "00000000",
                peerID: "10.0.0.\(attempt + 1)",
                origin: "http://10.0.1.\(attempt + 1):18765",
                now: now.addingTimeInterval(
                    Double(attempt) / 1_000))
            if attempt + 1
                < MobileDashboardManualPairingBroker
                    .maximumGlobalFailedAttempts {
                XCTAssertEqual(result, .invalid)
            } else if case .rateLimited = result {
                // Expected global exhaustion.
            } else {
                XCTFail("The global failure budget was not enforced.")
            }
        }
        guard case .rateLimited = broker.claim(
            candidate: "12345678",
            peerID: "10.0.9.1",
            origin: "http://10.0.9.1:18765",
            now: now.addingTimeInterval(1)) else {
            return XCTFail("A new peer cannot bypass the global budget.")
        }
        XCTAssertLessThanOrEqual(
            broker.trackedFailureKeyCount,
            MobileDashboardManualPairingBroker
                .maximumTrackedFailureKeys * 2)
        XCTAssertEqual(
            broker.claim(
                candidate: "12345678",
                peerID: "10.0.9.1",
                origin: "http://10.0.9.1:18765",
                now: now.addingTimeInterval(300)),
            .accepted)
    }

    func testPWAInstallCredentialIsOriginBoundExpiringAndRevokedByRotation()
        throws
    {
        let token = "master-token-must-not-leak"
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let origin = "http://studio-mac.local:18765"
        let installID = String(repeating: "I", count: 43)
        let credential = try XCTUnwrap(
            MobileDashboardPWAInstallCredential.issue(
                accessToken: token,
                origin: origin,
                issuedAt: now,
                installID: installID))

        XCTAssertTrue(credential.hasPrefix("v1.1800000000."))
        XCTAssertLessThanOrEqual(credential.utf8.count, 256)
        XCTAssertFalse(credential.contains(token))
        XCTAssertTrue(
            MobileDashboardPWAInstallCredential.validate(
                credential,
                accessToken: token,
                origin: origin,
                now: now,
                lifetime: 3_600))
        XCTAssertTrue(
            MobileDashboardPWAInstallCredential.validate(
                credential,
                accessToken: token,
                origin: origin,
                now: now,
                lifetime: 3_600),
            "Install claims are intentionally idempotent within their lifetime.")

        let replacement = credential.last == "A" ? "B" : "A"
        let tampered = String(credential.dropLast()) + replacement
        XCTAssertFalse(
            MobileDashboardPWAInstallCredential.validate(
                tampered,
                accessToken: token,
                origin: origin,
                now: now,
                lifetime: 3_600))
        XCTAssertFalse(
            MobileDashboardPWAInstallCredential.validate(
                credential,
                accessToken: token,
                origin: "http://192.168.1.20:18765",
                now: now,
                lifetime: 3_600),
            "A credential must not cross hosts even on the same LAN.")
        XCTAssertFalse(
            MobileDashboardPWAInstallCredential.validate(
                credential,
                accessToken: "rotated-master-token",
                origin: origin,
                now: now,
                lifetime: 3_600),
            "Rotating the master token revokes derived install credentials.")
        XCTAssertFalse(
            MobileDashboardPWAInstallCredential.validate(
                credential,
                accessToken: token,
                origin: origin,
                now: now.addingTimeInterval(3_600),
                lifetime: 3_600),
            "The credential is invalid at its expiration boundary.")
        XCTAssertFalse(
            MobileDashboardPWAInstallCredential.validate(
                credential,
                accessToken: token,
                origin: origin,
                now: now.addingTimeInterval(
                    -MobileDashboardPWAInstallCredential.maximumClockSkew - 1),
                lifetime: 3_600),
            "Credentials issued too far in the future must be rejected.")

        XCTAssertTrue(
            MobileDashboardPWAInstallCredential.validate(
                credential,
                accessToken: token,
                origin: origin,
                now: now.addingTimeInterval(1),
                lifetime: 3_600),
            "Validation is stateless and therefore survives a server restart.")
    }

    func testPWAInstallAuthorizationParserIsExactAndBounded() {
        let credential = "v1.1."
            + String(repeating: "I", count: 43)
            + "."
            + String(repeating: "S", count: 43)
        XCTAssertEqual(
            MobileDashboardHTTPServer.pwaInstallCredential(
                fromAuthorization: "PWAInstall \(credential)"),
            credential)

        for invalid in [
            nil,
            "Bearer \(credential)",
            "pwainstall \(credential)",
            "PWAInstall  \(credential)",
            "PWAInstall \(credential) suffix",
            "PWAInstall " + String(repeating: "A", count: 257),
        ] {
            XCTAssertNil(
                MobileDashboardHTTPServer.pwaInstallCredential(
                    fromAuthorization: invalid))
        }
    }

    func testInstallOriginAcceptsOnlyCurrentBonjourNameOrLocalAddresses() {
        XCTAssertEqual(
            MobileDashboardRequestOrigin.normalized(
                hostHeader: "Studio-Mac.local:18765",
                expectedLocalHostName: "Studio-Mac"),
            "http://studio-mac.local:18765")
        XCTAssertEqual(
            MobileDashboardRequestOrigin.normalized(
                hostHeader: "studio-mac.local.:80",
                expectedLocalHostName: "studio-mac.local"),
            "http://studio-mac.local")
        XCTAssertEqual(
            MobileDashboardRequestOrigin.normalized(
                hostHeader: "192.168.1.20:18765",
                expectedLocalHostName: nil),
            "http://192.168.1.20:18765")
        XCTAssertEqual(
            MobileDashboardRequestOrigin.normalized(
                hostHeader: "127.0.0.1:18765",
                expectedLocalHostName: nil),
            "http://127.0.0.1:18765")
        XCTAssertEqual(
            MobileDashboardRequestOrigin.normalized(
                hostHeader: "[::1]:18765",
                expectedLocalHostName: nil),
            "http://[::1]:18765")

        let rejected = [
            "other-mac.local:18765",
            "studio-mac.local:18765/path",
            "studio-mac.local:18765?token=bad",
            "user@studio-mac.local:18765",
            "8.8.8.8:18765",
            "example.com:18765",
            "localhost:18765",
            "192.168.1.20:",
            "192.168.1.20:bad",
            "192.168.1.20:18765\r\nX-Test: bad",
        ]
        for host in rejected {
            XCTAssertNil(
                MobileDashboardRequestOrigin.normalized(
                    hostHeader: host,
                    expectedLocalHostName: "studio-mac"),
                host)
        }
        XCTAssertNil(
            MobileDashboardRequestOrigin.normalized(
                hostHeader: "studio-mac.local:18765",
                expectedLocalHostName: nil))
    }

    func testCandidateAddressNormalizationAllowsOnlyPrivateBaseOrigins() {
        let accepted: [(String, String)] = [
            ("192.168.1.20", "http://192.168.1.20:18765"),
            ("10.0.0.4:19000", "http://10.0.0.4:19000"),
            (
                "http://172.16.0.8:18765",
                "http://172.16.0.8:18765"
            ),
            ("169.254.20.30", "http://169.254.20.30:18765"),
            ("Studio-Mac.local", "http://studio-mac.local:18765"),
            ("studio-mac.local.:80", "http://studio-mac.local"),
        ]
        for (input, expected) in accepted {
            XCTAssertEqual(
                MobileDashboardCandidateAddress.normalizedOrigin(input),
                expected,
                input)
        }

        let rejected = [
            "",
            "https://192.168.1.20:18765",
            "http://user@192.168.1.20:18765",
            "http://192.168.1.20:18765/",
            "http://192.168.1.20:18765/api/v1/health",
            "http://192.168.1.20:18765?token=secret",
            "http://192.168.1.20:18765/#token=secret",
            "127.0.0.1:18765",
            "8.8.8.8:18765",
            "203.0.113.5:18765",
            "localhost:18765",
            "mac.office.local:18765",
            "-mac.local:18765",
            "[fd00::1]:18765",
            "192.168.1.20:0",
            "192.168.1.20:65536",
            "192.168.1.20:bad",
        ]
        for input in rejected {
            XCTAssertNil(
                MobileDashboardCandidateAddress.normalizedOrigin(input),
                input)
        }
    }

    func testSensitiveCORSAllowsOnlyCurrentAccessOriginsAtServerPort() {
        XCTAssertNil(
            MobileDashboardHTTPServer.normalizedCurrentAccessOrigin(
                "http://127.0.0.1:18765",
                requiredPort: 18_765))
        XCTAssertEqual(
            MobileDashboardHTTPServer.normalizedCurrentAccessOrigin(
                "http://127.0.0.1:18765",
                requiredPort: 18_765,
                allowedHosts: ["127.0.0.1"]),
            "http://127.0.0.1:18765")
        XCTAssertNil(
            MobileDashboardHTTPServer.normalizedCurrentAccessOrigin(
                "http://127.0.0.1:18766",
                requiredPort: 18_765))
        XCTAssertNil(
            MobileDashboardHTTPServer.normalizedCurrentAccessOrigin(
                "http://other-machine.local:18765",
                requiredPort: 18_765))

        if let localName = MobileDashboardNetworkAddress.localHostName() {
            XCTAssertEqual(
                MobileDashboardHTTPServer.normalizedCurrentAccessOrigin(
                    "http://\(localName).local:18765",
                    requiredPort: 18_765),
                "http://\(localName).local:18765")
        }
        for address in MobileDashboardNetworkAddress.localIPv4Addresses() {
            XCTAssertEqual(
                MobileDashboardHTTPServer.normalizedCurrentAccessOrigin(
                    "http://\(address):18765",
                    requiredPort: 18_765),
                "http://\(address):18765")
        }
    }

    func testOnlyLocalAndLoopbackPeersAreAllowed() {
        let allowedHosts = [
            "127.0.0.1",
            "10.0.0.1",
            "172.16.0.1",
            "172.31.255.254",
            "192.168.1.2",
            "169.254.20.30",
            "::1",
            "fc00::1",
            "fd12:3456::1",
            "fe80::1",
            "[fe80::1%en0]",
            "::ffff:192.168.1.2",
        ]
        for host in allowedHosts {
            XCTAssertTrue(
                MobileDashboardNetworkAddress
                    .isLocalOrLoopbackHost(host),
                host)
        }

        let rejectedHosts = [
            "0.0.0.0",
            "8.8.8.8",
            "172.15.255.255",
            "172.32.0.1",
            "192.167.1.1",
            "224.0.0.1",
            "::",
            "2001:4860:4860::8888",
            "ff02::1",
            "localhost",
            "not-an-address",
        ]
        for host in rejectedHosts {
            XCTAssertFalse(
                MobileDashboardNetworkAddress
                    .isLocalOrLoopbackHost(host),
                host)
        }
    }

    func testHTTPServerEndpointGateRejectsPublicPeer() {
        XCTAssertTrue(
            MobileDashboardHTTPServer.isAllowedLocalEndpoint(
                .hostPort(
                    host: "192.168.20.3",
                    port: 49_152)))
        XCTAssertFalse(
            MobileDashboardHTTPServer.isAllowedLocalEndpoint(
                .hostPort(
                    host: "203.0.113.20",
                    port: 49_152)))
        XCTAssertFalse(
            MobileDashboardHTTPServer.isAllowedLocalEndpoint(
                .service(
                    name: "dashboard",
                    type: "_http._tcp",
                    domain: "local",
                    interface: nil)))
    }

    func testAllBundledDashboardResourcesAreReadable() throws {
        let resources = [
            ("index", "html"),
            ("app", "css"),
            ("app", "js"),
            ("manifest", "webmanifest"),
            ("icon-192", "png"),
            ("icon-512", "png"),
            ("icon-maskable-512", "png"),
            ("apple-touch-icon", "png"),
            ("wake-ambient", "mp4"),
        ]

        for (name, fileExtension) in resources {
            let url = try XCTUnwrap(
                MobileDashboardHTTPServer.staticResourceURL(
                    name: name,
                    extension: fileExtension),
                "\(name).\(fileExtension)")
            let data = try Data(contentsOf: url)
            XCTAssertGreaterThan(
                data.count,
                100,
                "\(name).\(fileExtension)")
        }
    }

    func testWakeAmbientVideoIsSmallSilentAndFastStart() throws {
        let url = try XCTUnwrap(
            MobileDashboardHTTPServer.staticResourceURL(
                name: "wake-ambient",
                extension: "mp4"))
        let data = try Data(contentsOf: url)

        XCTAssertGreaterThan(data.count, 100)
        XCTAssertLessThan(
            data.count,
            256 * 1_024,
            "The optional wake fallback must remain a small bundled asset.")
        let boxTypes = topLevelMP4BoxTypes(in: data)
        let moovIndex = try XCTUnwrap(boxTypes.firstIndex(of: "moov"))
        let mediaDataIndex = try XCTUnwrap(
            boxTypes.firstIndex(of: "mdat"))
        XCTAssertLessThan(
            moovIndex,
            mediaDataIndex,
            "The moov atom must precede mdat for Safari fast start.")
        XCTAssertNotNil(
            data.range(of: Data("vide".utf8)),
            "The MP4 must contain a video handler.")
        XCTAssertNil(
            data.range(of: Data("soun".utf8)),
            "The fallback MP4 must not contain an audio track.")
    }

    func testMissingDashboardResourceDoesNotResolve() {
        XCTAssertNil(
            MobileDashboardHTTPServer.staticResourceURL(
                name: "missing-\(UUID())",
                extension: "mp4"))
    }

    func testDashboardManifestAndHTMLDeclareInstallAssetsWithoutAWorker()
        throws
    {
        let manifestURL = try XCTUnwrap(
            MobileDashboardHTTPServer.staticResourceURL(
                name: "manifest",
                extension: "webmanifest"))
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData)
                as? [String: Any])
        XCTAssertEqual(manifest["id"] as? String, "/")
        XCTAssertEqual(manifest["start_url"] as? String, "/")
        XCTAssertEqual(manifest["scope"] as? String, "/")
        XCTAssertEqual(
            manifest["display"] as? String,
            "standalone")
        let icons = try XCTUnwrap(
            manifest["icons"] as? [[String: Any]])
        XCTAssertTrue(
            icons.contains {
                $0["src"] as? String == "/icon-192.png"
                    && $0["sizes"] as? String == "192x192"
                    && $0["type"] as? String == "image/png"
            })
        XCTAssertTrue(
            icons.contains {
                $0["src"] as? String == "/icon-512.png"
                    && $0["sizes"] as? String == "512x512"
                    && $0["type"] as? String == "image/png"
            })
        XCTAssertTrue(
            icons.contains {
                $0["src"] as? String
                    == "/icon-maskable-512.png"
                    && $0["purpose"] as? String == "maskable"
            })

        let htmlURL = try XCTUnwrap(
            MobileDashboardHTTPServer.staticResourceURL(
                name: "index",
                extension: "html"))
        let html = try String(
            contentsOf: htmlURL,
            encoding: .utf8)
        XCTAssertTrue(
            html.contains(
                #"rel="manifest" href="/manifest.webmanifest""#))
        XCTAssertTrue(
            html.contains(
                #"rel="apple-touch-icon""#))

        let scriptURL = try XCTUnwrap(
            MobileDashboardHTTPServer.staticResourceURL(
                name: "app",
                extension: "js"))
        let script = try String(
            contentsOf: scriptURL,
            encoding: .utf8)
        XCTAssertTrue(
            script.contains(
                #""/api/v1/pwa/bootstrap""#))
        XCTAssertTrue(
            script.contains(
                #""/api/v1/pwa/claim""#))
        XCTAssertTrue(
            script.contains(
                #""(display-mode: standalone)""#))
        XCTAssertTrue(
            script.contains(
                #"window.navigator.standalone === true"#))
        XCTAssertTrue(
            script.contains(
                #"credentials: "include""#))
        XCTAssertFalse(script.contains("serviceWorker.register"))
    }

    func testLightColorSchemeIsInjectedIntoFirstPaintAndManifest()
        async throws
    {
        let port = UInt16.random(in: 40_000...60_000)
        let ready = expectation(
            description: "Light dashboard listener is ready")
        let server = MobileDashboardHTTPServer(
            stateHandler: { state in
                if case .ready = state {
                    ready.fulfill()
                }
            },
            viewerCountHandler: { _ in })
        server.start(
            port: port,
            accessToken: "test-only-access-token",
            colorScheme: .light)
        await fulfillment(of: [ready], timeout: 5)
        defer { server.stop() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let rootURL = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)/"))
        var rootRequest = URLRequest(url: rootURL)
        rootRequest.timeoutInterval = 5
        let (rootData, rootResponse) = try await session.data(
            for: rootRequest)
        XCTAssertEqual(
            (rootResponse as? HTTPURLResponse)?.statusCode,
            200)
        let html = try XCTUnwrap(
            String(data: rootData, encoding: .utf8))
        XCTAssertTrue(html.contains(#"data-color-scheme="light""#))
        XCTAssertTrue(
            html.contains(
                "name=\"theme-color\" content=\"#f6f7f4\""))
        XCTAssertTrue(
            html.contains(
                #"name="color-scheme" content="light""#))
        XCTAssertTrue(
            html.contains(
                #"name="apple-mobile-web-app-status-bar-style" content="default""#))

        let manifestURL = rootURL.appendingPathComponent(
            "manifest.webmanifest")
        var manifestRequest = URLRequest(url: manifestURL)
        manifestRequest.timeoutInterval = 5
        let (manifestData, manifestResponse) = try await session.data(
            for: manifestRequest)
        XCTAssertEqual(
            (manifestResponse as? HTTPURLResponse)?.statusCode,
            200)
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData)
                as? [String: Any])
        XCTAssertEqual(manifest["background_color"] as? String, "#f6f7f4")
        XCTAssertEqual(manifest["theme_color"] as? String, "#f6f7f4")
    }

    func testAutomaticColorSchemeIsInjectedForBrowserResolution()
        async throws
    {
        let port = UInt16.random(in: 40_000...60_000)
        let ready = expectation(
            description: "Automatic dashboard listener is ready")
        let server = MobileDashboardHTTPServer(
            stateHandler: { state in
                if case .ready = state {
                    ready.fulfill()
                }
            },
            viewerCountHandler: { _ in })
        server.start(
            port: port,
            accessToken: "test-only-access-token",
            colorScheme: .automatic)
        await fulfillment(of: [ready], timeout: 5)
        defer { server.stop() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let rootURL = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)/"))
        var request = URLRequest(url: rootURL)
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual(
            (response as? HTTPURLResponse)?.statusCode,
            200)
        let html = try XCTUnwrap(
            String(data: data, encoding: .utf8))
        XCTAssertTrue(html.contains(#"data-color-scheme="auto""#))
        XCTAssertTrue(
            html.contains(
                #"name="color-scheme" content="light dark""#))
        XCTAssertTrue(
            html.contains(
                ##"name="theme-color" content="#000000""##))
    }

    func testLoopbackHealthEndpointStartsAndReturnsReadOnlyStatus()
        async throws
    {
        let port = UInt16.random(in: 40_000...60_000)
        let ready = expectation(
            description: "Mobile dashboard listener is ready")
        let server = MobileDashboardHTTPServer(
            stateHandler: { state in
                if case .ready = state {
                    ready.fulfill()
                }
            },
            viewerCountHandler: { _ in },
            sensitiveCORSHostProvider: { ["127.0.0.2"] })
        server.start(
            port: port,
            accessToken: "test-only-access-token")
        await fulfillment(of: [ready], timeout: 5)
        defer {
            server.stop()
        }

        let url = try XCTUnwrap(
            URL(
                string:
                    "http://127.0.0.1:\(port)/api/v1/health"))
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(
            for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(http.statusCode, 200)
        let health = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any])
        XCTAssertEqual(health["status"] as? String, "ok")
        XCTAssertEqual(
            health["requiresPairingCode"] as? Bool,
            true,
            "The low-level server defaults closed unless its owner opts out.")
        XCTAssertEqual(
            http.value(
                forHTTPHeaderField:
                    "Cross-Origin-Resource-Policy"),
            "same-origin")
        XCTAssertEqual(
            http.value(forHTTPHeaderField: "Cache-Control"),
            "no-store")
        XCTAssertTrue(
            http.value(
                forHTTPHeaderField:
                    "Content-Security-Policy"
            )?.contains("default-src 'none'") == true)

        let candidateOrigin = "http://192.168.1.50:18765"
        let trustedOrigin = "http://127.0.0.2:\(port)"
        var corsHealthRequest = URLRequest(url: url)
        corsHealthRequest.timeoutInterval = 5
        corsHealthRequest.setValue(
            candidateOrigin,
            forHTTPHeaderField: "Origin")
        let (_, corsHealthResponse) =
            try await URLSession.shared.data(for: corsHealthRequest)
        let corsHealthHTTP = try XCTUnwrap(
            corsHealthResponse as? HTTPURLResponse)
        XCTAssertEqual(corsHealthHTTP.statusCode, 200)
        XCTAssertEqual(
            corsHealthHTTP.value(
                forHTTPHeaderField: "Access-Control-Allow-Origin"),
            candidateOrigin)
        XCTAssertNil(
            corsHealthHTTP.value(
                forHTTPHeaderField: "Access-Control-Allow-Credentials"))

        var preflight = URLRequest(url: url)
        preflight.httpMethod = "OPTIONS"
        preflight.timeoutInterval = 5
        preflight.setValue(
            candidateOrigin,
            forHTTPHeaderField: "Origin")
        preflight.setValue(
            "GET",
            forHTTPHeaderField: "Access-Control-Request-Method")
        preflight.setValue(
            "true",
            forHTTPHeaderField:
                "Access-Control-Request-Private-Network")
        let (_, preflightResponse) =
            try await URLSession.shared.data(for: preflight)
        let preflightHTTP = try XCTUnwrap(
            preflightResponse as? HTTPURLResponse)
        XCTAssertEqual(preflightHTTP.statusCode, 204)
        XCTAssertEqual(
            preflightHTTP.value(
                forHTTPHeaderField: "Access-Control-Allow-Origin"),
            candidateOrigin)
        XCTAssertEqual(
            preflightHTTP.value(
                forHTTPHeaderField: "Access-Control-Allow-Methods"),
            "GET")
        XCTAssertEqual(
            preflightHTTP.value(
                forHTTPHeaderField:
                    "Access-Control-Allow-Private-Network"),
            "true")

        var credentialedPreflight = preflight
        credentialedPreflight.setValue(
            "authorization",
            forHTTPHeaderField: "Access-Control-Request-Headers")
        let (_, credentialedPreflightResponse) =
            try await URLSession.shared.data(
                for: credentialedPreflight)
        XCTAssertEqual(
            (credentialedPreflightResponse as? HTTPURLResponse)?
                .statusCode,
            403,
            "Only anonymous read-only health probing receives CORS headers.")

        var publicOriginHealth = corsHealthRequest
        publicOriginHealth.setValue(
            "https://example.com",
            forHTTPHeaderField: "Origin")
        let (_, publicOriginResponse) =
            try await URLSession.shared.data(for: publicOriginHealth)
        let publicOriginHTTP = try XCTUnwrap(
            publicOriginResponse as? HTTPURLResponse)
        XCTAssertEqual(publicOriginHTTP.statusCode, 403)
        XCTAssertNil(
            publicOriginHTTP.value(
                forHTTPHeaderField: "Access-Control-Allow-Origin"))

        for protectedPath in [
            "api/v1/pwa/bootstrap",
            "api/v1/pwa/claim",
        ] {
            let protectedURL = try XCTUnwrap(
                URL(
                    string: "http://127.0.0.1:\(port)/\(protectedPath)"))
            var protectedPreflight = URLRequest(url: protectedURL)
            protectedPreflight.httpMethod = "OPTIONS"
            protectedPreflight.timeoutInterval = 5
            protectedPreflight.setValue(
                candidateOrigin,
                forHTTPHeaderField: "Origin")
            protectedPreflight.setValue(
                "POST",
                forHTTPHeaderField: "Access-Control-Request-Method")
            protectedPreflight.setValue(
                "authorization",
                forHTTPHeaderField: "Access-Control-Request-Headers")
            let (_, protectedResponse) =
                try await URLSession.shared.data(for: protectedPreflight)
            let protectedHTTP = try XCTUnwrap(
                protectedResponse as? HTTPURLResponse)
            XCTAssertEqual(protectedHTTP.statusCode, 405, protectedPath)
            XCTAssertNil(
                protectedHTTP.value(
                    forHTTPHeaderField:
                        "Access-Control-Allow-Origin"),
                protectedPath)
        }

        let eventsPreflightURL = try XCTUnwrap(
            URL(
                string:
                    "http://127.0.0.1:\(port)/api/v1/events"))
        var eventsPreflight = URLRequest(url: eventsPreflightURL)
        eventsPreflight.httpMethod = "OPTIONS"
        eventsPreflight.timeoutInterval = 5
        eventsPreflight.setValue(
            trustedOrigin,
            forHTTPHeaderField: "Origin")
        eventsPreflight.setValue(
            "GET",
            forHTTPHeaderField: "Access-Control-Request-Method")
        eventsPreflight.setValue(
            "authorization, cache-control",
            forHTTPHeaderField: "Access-Control-Request-Headers")
        let (_, eventsPreflightResponse) = try await URLSession.shared
            .data(for: eventsPreflight)
        let eventsPreflightHTTP = try XCTUnwrap(
            eventsPreflightResponse as? HTTPURLResponse)
        XCTAssertEqual(eventsPreflightHTTP.statusCode, 204)
        XCTAssertEqual(
            eventsPreflightHTTP.value(
                forHTTPHeaderField: "Access-Control-Allow-Origin"),
            trustedOrigin)
        XCTAssertEqual(
            eventsPreflightHTTP.value(
                forHTTPHeaderField: "Access-Control-Allow-Headers"),
            "Authorization, Cache-Control")

        let crossOriginEventsURL = try XCTUnwrap(
            URL(
                string: "http://127.0.0.1:\(port)/api/v1/events"))
        var crossOriginEvents = URLRequest(url: crossOriginEventsURL)
        crossOriginEvents.timeoutInterval = 5
        crossOriginEvents.setValue(
            trustedOrigin,
            forHTTPHeaderField: "Origin")
        crossOriginEvents.setValue(
            "Bearer wrong-token",
            forHTTPHeaderField: "Authorization")
        let (_, crossOriginEventsResponse) =
            try await URLSession.shared.data(for: crossOriginEvents)
        let crossOriginEventsHTTP = try XCTUnwrap(
            crossOriginEventsResponse as? HTTPURLResponse)
        XCTAssertEqual(crossOriginEventsHTTP.statusCode, 401)
        XCTAssertEqual(
            crossOriginEventsHTTP.value(
                forHTTPHeaderField: "Access-Control-Allow-Origin"),
            trustedOrigin)

        var writeRequest = URLRequest(url: url)
        writeRequest.httpMethod = "POST"
        writeRequest.timeoutInterval = 5
        let (_, writeResponse) = try await URLSession.shared.data(
            for: writeRequest)
        let writeHTTP = try XCTUnwrap(
            writeResponse as? HTTPURLResponse)
        XCTAssertEqual(writeHTTP.statusCode, 405)
        XCTAssertEqual(
            writeHTTP.value(forHTTPHeaderField: "Allow"),
            "GET, HEAD")

        let eventsURL = try XCTUnwrap(
            URL(
                string:
                    "http://127.0.0.1:\(port)/api/v1/events"))
        var unauthenticatedRequest = URLRequest(url: eventsURL)
        unauthenticatedRequest.timeoutInterval = 5
        let (_, unauthenticatedResponse) =
            try await URLSession.shared.data(
                for: unauthenticatedRequest)
        XCTAssertEqual(
            (unauthenticatedResponse as? HTTPURLResponse)?
                .statusCode,
            401)
    }

    @MainActor
    func testPrivacyConfigurationBroadcastsLiveOnTheSameServer()
        async throws
    {
        let suiteName = "MobileDashboardLivePrivacyConfig.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = makeDisabledService(defaults: defaults)
        let port = UInt16.random(in: 40_000...60_000)
        let token = "live-privacy-config-token"
        let ready = expectation(description: "Privacy config server ready")
        let viewer = expectation(description: "Privacy config viewer ready")
        let server = MobileDashboardHTTPServer(
            stateHandler: { state in
                if case .ready = state { ready.fulfill() }
            },
            viewerCountHandler: { count in
                if count == 1 { viewer.fulfill() }
            })
        server.start(port: port, accessToken: token)
        await fulfillment(of: [ready], timeout: 5)
        defer { server.stop() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let eventsURL = try XCTUnwrap(URL(
            string: "http://127.0.0.1:\(port)/api/v1/events"))
        var request = URLRequest(url: eventsURL)
        request.timeoutInterval = 5
        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization")
        let (bytes, rawResponse) = try await session.bytes(for: request)
        let response = try XCTUnwrap(rawResponse as? HTTPURLResponse)
        XCTAssertEqual(response.statusCode, 200)
        let serverInstanceID = try XCTUnwrap(
            response.value(
                forHTTPHeaderField: "X-AI-Quota-Server-Instance"))
        await fulfillment(of: [viewer], timeout: 5)

        func envelopeData() throws -> Data {
            try JSONEncoder().encode(MobileDashboardEventEnvelope(
                oledProtectionEnabled: service.oledProtectionEnabled,
                experimentalWakeMediaEnabled:
                    service.experimentalWakeMediaEnabled,
                activityBackgroundEffect:
                    service.activityBackgroundEffect,
                colorScheme: service.colorScheme,
                idleBlackoutMarqueeEnabled:
                    service.idleBlackoutMarqueeEnabled,
                snapshot: snapshot(
                    generatedAt: Date(),
                    connectivity: "online")))
        }

        var iterator = bytes.lines.makeAsyncIterator()
        server.broadcast(snapshotData: try envelopeData())
        var firstPayload: [String: Any]?
        while let line = try await iterator.next() {
            guard line.hasPrefix("data: ") else { continue }
            let data = Data(line.dropFirst("data: ".count).utf8)
            firstPayload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data)
                    as? [String: Any])
            break
        }
        XCTAssertEqual(
            firstPayload?["idleBlackoutMarqueeEnabled"] as? Bool,
            true)
        XCTAssertEqual(firstPayload?["colorScheme"] as? String, "auto")
        XCTAssertTrue(service.masksAccountNames)

        service.idleBlackoutMarqueeEnabled = false
        service.colorScheme = .light
        service.masksAccountNames = false
        server.broadcast(snapshotData: try envelopeData())
        var secondPayload: [String: Any]?
        while let line = try await iterator.next() {
            guard line.hasPrefix("data: ") else { continue }
            let data = Data(line.dropFirst("data: ".count).utf8)
            secondPayload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data)
                    as? [String: Any])
            break
        }

        XCTAssertEqual(
            secondPayload?["idleBlackoutMarqueeEnabled"] as? Bool,
            false)
        XCTAssertEqual(secondPayload?["colorScheme"] as? String, "light")
        XCTAssertFalse(service.masksAccountNames)
        XCTAssertEqual(serverInstanceID.utf8.count, 22)
        XCTAssertNotNil(
            firstPayload,
            "Both updates must travel over one uninterrupted SSE stream.")
        XCTAssertNotNil(secondPayload)
    }

    func testPairingPolicyControlsOnlyTokenIssuanceAndNeverOpensEvents()
        async throws
    {
        let port = UInt16.random(in: 40_000...54_999)
        let ready = expectation(
            description: "Pairing-policy listener is ready")
        let token = "pairing-policy-stable-master-token"
        let server = MobileDashboardHTTPServer(
            stateHandler: { state in
                if case .ready = state { ready.fulfill() }
            },
            viewerCountHandler: { _ in },
            sensitiveCORSHostProvider: { ["127.0.0.1"] })
        server.start(
            port: port,
            accessToken: token,
            requiresPairingCode: false)
        await fulfillment(of: [ready], timeout: 5)
        defer { server.stop() }

        let origin = "http://127.0.0.1:\(port)"
        let baseURL = try XCTUnwrap(URL(string: origin))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        func response(
            path: String,
            method: String = "GET",
            origin requestOrigin: String? = nil,
            jsonBody: String? = nil,
            authorization: String? = nil
        ) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(
                url: baseURL.appendingPathComponent(path))
            request.httpMethod = method
            request.timeoutInterval = 5
            if let requestOrigin {
                request.setValue(
                    requestOrigin,
                    forHTTPHeaderField: "Origin")
            }
            if let jsonBody {
                request.httpBody = Data(jsonBody.utf8)
                request.setValue(
                    "application/json",
                    forHTTPHeaderField: "Content-Type")
            }
            if let authorization {
                request.setValue(
                    authorization,
                    forHTTPHeaderField: "Authorization")
            }
            let (data, rawResponse) = try await session.data(for: request)
            return (
                data,
                try XCTUnwrap(rawResponse as? HTTPURLResponse))
        }

        let (healthData, healthResponse) = try await response(
            path: "api/v1/health")
        XCTAssertEqual(healthResponse.statusCode, 200)
        let health = try XCTUnwrap(
            JSONSerialization.jsonObject(with: healthData)
                as? [String: Any])
        XCTAssertEqual(health["requiresPairingCode"] as? Bool, false)

        let (automaticData, automaticResponse) = try await response(
            path: "api/v1/pwa/claim",
            method: "POST",
            origin: origin)
        XCTAssertEqual(automaticResponse.statusCode, 200)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: automaticData)
                as? [String: String],
            ["token": token])

        let (_, missingOriginResponse) = try await response(
            path: "api/v1/pwa/claim",
            method: "POST")
        XCTAssertEqual(missingOriginResponse.statusCode, 403)
        let (_, crossOriginResponse) = try await response(
            path: "api/v1/pwa/claim",
            method: "POST",
            origin: "http://127.0.0.1:\(port + 1)")
        XCTAssertEqual(crossOriginResponse.statusCode, 403)

        let (disabledManualData, disabledManualResponse) =
            try await response(
                path: "api/v1/pwa/manual-claim",
                method: "POST",
                origin: origin,
                jsonBody: "{\"code\":\"12345678\"}")
        XCTAssertEqual(disabledManualResponse.statusCode, 409)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: disabledManualData)
                as? [String: String],
            ["error": "pairing_disabled"])
        XCTAssertEqual(
            disabledManualResponse.value(
                forHTTPHeaderField: "Access-Control-Allow-Origin"),
            origin)

        let (_, anonymousEventsResponse) = try await response(
            path: "api/v1/events")
        XCTAssertEqual(anonymousEventsResponse.statusCode, 401)

        let firstCode = "12345678"
        server.updatePairingPolicy(
            requiresPairingCode: true,
            manualPairingCode: firstCode,
            manualPairingCodeExpiresAt:
                Date().addingTimeInterval(300))

        let (_, protectedClaimResponse) = try await response(
            path: "api/v1/pwa/claim",
            method: "POST",
            origin: origin)
        XCTAssertEqual(protectedClaimResponse.statusCode, 401)
        let (manualData, manualResponse) = try await response(
            path: "api/v1/pwa/manual-claim",
            method: "POST",
            origin: origin,
            jsonBody: "{\"code\":\"\(firstCode)\"}")
        XCTAssertEqual(manualResponse.statusCode, 200)
        XCTAssertEqual(
            (try JSONSerialization.jsonObject(with: manualData)
                as? [String: String])?["token"],
            token,
            "Changing policy must not rotate the existing bearer.")

        let eventSession = URLSession(configuration: .ephemeral)
        var authorizedEvents = URLRequest(
            url: baseURL.appendingPathComponent("api/v1/events"))
        authorizedEvents.timeoutInterval = 5
        authorizedEvents.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization")
        let (_, rawEventsResponse) = try await eventSession.bytes(
            for: authorizedEvents)
        XCTAssertEqual(
            (rawEventsResponse as? HTTPURLResponse)?.statusCode,
            200,
            "A bearer issued before opt-in remains an authorized device.")
        eventSession.invalidateAndCancel()

        server.updatePairingPolicy(
            requiresPairingCode: false,
            manualPairingCode: nil,
            manualPairingCodeExpiresAt: nil)
        let (_, clearedCodeResponse) = try await response(
            path: "api/v1/pwa/manual-claim",
            method: "POST",
            origin: origin,
            jsonBody: "{\"code\":\"\(firstCode)\"}")
        XCTAssertEqual(clearedCodeResponse.statusCode, 409)

        let secondCode = "87654321"
        server.updatePairingPolicy(
            requiresPairingCode: true,
            manualPairingCode: secondCode,
            manualPairingCodeExpiresAt:
                Date().addingTimeInterval(300))
        let (_, staleCodeResponse) = try await response(
            path: "api/v1/pwa/manual-claim",
            method: "POST",
            origin: origin,
            jsonBody: "{\"code\":\"\(firstCode)\"}")
        XCTAssertEqual(staleCodeResponse.statusCode, 401)
        let (newCodeData, newCodeResponse) = try await response(
            path: "api/v1/pwa/manual-claim",
            method: "POST",
            origin: origin,
            jsonBody: "{\"code\":\"\(secondCode)\"}")
        XCTAssertEqual(newCodeResponse.statusCode, 200)
        XCTAssertEqual(
            (try JSONSerialization.jsonObject(with: newCodeData)
                as? [String: String])?["token"],
            token)
    }

    func testManualClaimCORSValidationAndAuthenticatedEventStream()
        async throws
    {
        let port = UInt16.random(in: 40_000...44_999)
        let ready = expectation(
            description: "Manual pairing listener is ready")
        let token = "manual-claim-test-master-token"
        let code = "12345678"
        let server = MobileDashboardHTTPServer(
            stateHandler: { state in
                if case .ready = state {
                    ready.fulfill()
                }
            },
            viewerCountHandler: { _ in },
            sensitiveCORSHostProvider: { ["127.0.0.2"] })
        server.start(
            port: port,
            accessToken: token,
            manualPairingCode: code,
            manualPairingCodeExpiresAt:
                Date().addingTimeInterval(300))
        await fulfillment(of: [ready], timeout: 5)
        defer { server.stop() }

        let endpoint = try XCTUnwrap(URL(
            string:
                "http://127.0.0.1:\(port)/api/v1/pwa/manual-claim"))
        let trustedOrigin = "http://127.0.0.2:\(port)"
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        var preflight = URLRequest(url: endpoint)
        preflight.httpMethod = "OPTIONS"
        preflight.timeoutInterval = 5
        preflight.setValue(trustedOrigin, forHTTPHeaderField: "Origin")
        preflight.setValue(
            "POST",
            forHTTPHeaderField: "Access-Control-Request-Method")
        preflight.setValue(
            "content-type",
            forHTTPHeaderField: "Access-Control-Request-Headers")
        preflight.setValue(
            "true",
            forHTTPHeaderField:
                "Access-Control-Request-Private-Network")
        let (_, preflightResponse) = try await session.data(
            for: preflight)
        let preflightHTTP = try XCTUnwrap(
            preflightResponse as? HTTPURLResponse)
        XCTAssertEqual(preflightHTTP.statusCode, 204)
        XCTAssertEqual(
            preflightHTTP.value(
                forHTTPHeaderField: "Access-Control-Allow-Origin"),
            trustedOrigin)
        XCTAssertEqual(
            preflightHTTP.value(
                forHTTPHeaderField: "Access-Control-Allow-Headers"),
            "Content-Type")
        XCTAssertEqual(
            preflightHTTP.value(
                forHTTPHeaderField:
                    "Access-Control-Allow-Private-Network"),
            "true")
        XCTAssertNil(
            preflightHTTP.value(
                forHTTPHeaderField: "Access-Control-Allow-Credentials"))

        for rejectedOrigin in [
            "http://10.255.255.254:\(port)",
            "http://127.0.0.2:\(Int(port) + 1)",
            "http://other-machine.local:\(port)",
        ] {
            var request = preflight
            request.setValue(
                rejectedOrigin,
                forHTTPHeaderField: "Origin")
            let (_, response) = try await session.data(for: request)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, 403, rejectedOrigin)
            XCTAssertNil(
                http.value(
                    forHTTPHeaderField:
                        "Access-Control-Allow-Origin"),
                rejectedOrigin)
        }

        func claimRequest(
            body: String,
            contentType: String = "application/json",
            origin: String? = nil
        ) -> URLRequest {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 5
            request.httpBody = Data(body.utf8)
            request.setValue(
                contentType,
                forHTTPHeaderField: "Content-Type")
            request.setValue(
                origin ?? trustedOrigin,
                forHTTPHeaderField: "Origin")
            return request
        }

        let (wrongData, wrongResponse) = try await session.data(
            for: claimRequest(body: "{\"code\":\"00000000\"}"))
        XCTAssertEqual(
            (wrongResponse as? HTTPURLResponse)?.statusCode,
            401)
        XCTAssertEqual(
            String(data: wrongData, encoding: .utf8),
            "{\"error\":\"invalid_pairing_code\"}")

        let (_, typeResponse) = try await session.data(
            for: claimRequest(
                body: "{\"code\":\"12345678\"}",
                contentType: "text/plain"))
        XCTAssertEqual(
            (typeResponse as? HTTPURLResponse)?.statusCode,
            415)

        let (_, invalidResponse) = try await session.data(
            for: claimRequest(
                body: "{\"code\":\"12345678\",\"extra\":true}"))
        XCTAssertEqual(
            (invalidResponse as? HTTPURLResponse)?.statusCode,
            400)

        var credentialedRequest = claimRequest(
            body: "{\"code\":\"12345678\"}")
        credentialedRequest.setValue(
            "session=not-allowed",
            forHTTPHeaderField: "Cookie")
        let (_, credentialedResponse) = try await session.data(
            for: credentialedRequest)
        XCTAssertEqual(
            (credentialedResponse as? HTTPURLResponse)?.statusCode,
            403)

        let goodRequest = claimRequest(
            body: "{\"code\":\"12345678\"}")
        var claimedInstanceID = ""
        for attempt in 1...4 {
            let (data, response) = try await session.data(
                for: goodRequest)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            if attempt <= 3 {
                XCTAssertEqual(http.statusCode, 200)
                XCTAssertEqual(
                    http.value(
                        forHTTPHeaderField: "Access-Control-Allow-Origin"),
                    trustedOrigin)
                XCTAssertEqual(
                    http.value(forHTTPHeaderField: "Cache-Control"),
                    "no-store")
                XCTAssertEqual(
                    http.value(
                        forHTTPHeaderField:
                            "Cross-Origin-Resource-Policy"),
                    "cross-origin")
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: data)
                        as? [String: String])
                XCTAssertEqual(object["token"], token)
                claimedInstanceID = try XCTUnwrap(
                    object["serverInstanceID"])
                XCTAssertEqual(claimedInstanceID.utf8.count, 22)
                XCTAssertFalse(
                    endpoint.absoluteString.contains(token))
            } else {
                XCTAssertEqual(http.statusCode, 429)
                XCTAssertNotNil(
                    http.value(forHTTPHeaderField: "Retry-After"))
            }
        }

        let eventsURL = try XCTUnwrap(URL(
            string:
                "http://127.0.0.1:\(port)/api/v1/events"))
        var eventsRequest = URLRequest(url: eventsURL)
        eventsRequest.timeoutInterval = 5
        eventsRequest.setValue(
            trustedOrigin,
            forHTTPHeaderField: "Origin")
        eventsRequest.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization")
        let eventSession = URLSession(configuration: .ephemeral)
        defer { eventSession.invalidateAndCancel() }
        let (_, eventsResponse) = try await eventSession.bytes(
            for: eventsRequest)
        let eventsHTTP = try XCTUnwrap(
            eventsResponse as? HTTPURLResponse)
        XCTAssertEqual(eventsHTTP.statusCode, 200)
        XCTAssertEqual(
            eventsHTTP.value(
                forHTTPHeaderField: "Access-Control-Allow-Origin"),
            trustedOrigin)
        XCTAssertEqual(
            eventsHTTP.value(
                forHTTPHeaderField: "Access-Control-Expose-Headers"),
            "X-AI-Quota-Server-Instance")
        XCTAssertEqual(
            eventsHTTP.value(
                forHTTPHeaderField: "X-AI-Quota-Server-Instance"),
            claimedInstanceID)
    }

    func testLoopbackWakeVideoSupportsSafariByteRangesAndSecurityHeaders()
        async throws
    {
        let port = UInt16.random(in: 55_000...60_000)
        let ready = expectation(
            description: "Wake video listener is ready")
        let server = MobileDashboardHTTPServer(
            stateHandler: { state in
                if case .ready = state {
                    ready.fulfill()
                }
            },
            viewerCountHandler: { _ in })
        server.start(
            port: port,
            accessToken: "test-only-access-token")
        await fulfillment(of: [ready], timeout: 5)
        defer {
            server.stop()
        }

        let resourceURL = try XCTUnwrap(
            MobileDashboardHTTPServer.staticResourceURL(
                name: "wake-ambient",
                extension: "mp4"))
        let expected = try Data(contentsOf: resourceURL)
        let url = try XCTUnwrap(
            URL(
                string:
                    "http://127.0.0.1:\(port)/wake-ambient.mp4"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
        }

        var fullRequest = URLRequest(url: url)
        fullRequest.timeoutInterval = 5
        let (fullData, fullResponse) = try await session.data(
            for: fullRequest)
        let fullHTTP = try XCTUnwrap(
            fullResponse as? HTTPURLResponse)
        XCTAssertEqual(fullHTTP.statusCode, 200)
        XCTAssertEqual(fullData, expected)
        XCTAssertEqual(
            fullHTTP.value(forHTTPHeaderField: "Content-Type"),
            "video/mp4")
        XCTAssertEqual(
            fullHTTP.value(forHTTPHeaderField: "Content-Length"),
            String(expected.count))
        XCTAssertEqual(
            fullHTTP.value(forHTTPHeaderField: "Accept-Ranges"),
            "bytes")
        XCTAssertEqual(
            fullHTTP.value(forHTTPHeaderField: "Cache-Control"),
            "no-cache")
        XCTAssertTrue(
            fullHTTP.value(
                forHTTPHeaderField: "Content-Security-Policy"
            )?.contains("media-src 'self'") == true)
        let permissionsPolicy = try XCTUnwrap(
            fullHTTP.value(
                forHTTPHeaderField: "Permissions-Policy"))
        XCTAssertTrue(
            permissionsPolicy.contains("screen-wake-lock=(self)"))
        XCTAssertFalse(permissionsPolicy.contains("wake-lock=()"))
        XCTAssertEqual(
            fullHTTP.value(
                forHTTPHeaderField: "X-Content-Type-Options"),
            "nosniff")
        XCTAssertEqual(
            fullHTTP.value(
                forHTTPHeaderField: "Cross-Origin-Resource-Policy"),
            "same-origin")

        var fullRangeRequest = URLRequest(url: url)
        fullRangeRequest.timeoutInterval = 5
        fullRangeRequest.setValue(
            "bytes=0-\(expected.count - 1)",
            forHTTPHeaderField: "Range")
        let (fullRangeData, fullRangeResponse) =
            try await session.data(for: fullRangeRequest)
        let fullRangeHTTP = try XCTUnwrap(
            fullRangeResponse as? HTTPURLResponse)
        XCTAssertEqual(fullRangeHTTP.statusCode, 206)
        XCTAssertEqual(fullRangeData, expected)
        XCTAssertEqual(
            fullRangeHTTP.value(
                forHTTPHeaderField: "Content-Range"),
            "bytes 0-\(expected.count - 1)/\(expected.count)")

        var partialRequest = URLRequest(url: url)
        partialRequest.timeoutInterval = 5
        partialRequest.setValue(
            "bytes=0-31",
            forHTTPHeaderField: "Range")
        let (partialData, partialResponse) =
            try await session.data(for: partialRequest)
        let partialHTTP = try XCTUnwrap(
            partialResponse as? HTTPURLResponse)
        XCTAssertEqual(partialHTTP.statusCode, 206)
        XCTAssertEqual(partialData, expected.subdata(in: 0..<32))
        XCTAssertEqual(
            partialHTTP.value(forHTTPHeaderField: "Content-Type"),
            "video/mp4")
        XCTAssertEqual(
            partialHTTP.value(forHTTPHeaderField: "Content-Length"),
            "32")
        XCTAssertEqual(
            partialHTTP.value(forHTTPHeaderField: "Content-Range"),
            "bytes 0-31/\(expected.count)")

        var suffixRequest = URLRequest(url: url)
        suffixRequest.timeoutInterval = 5
        suffixRequest.setValue(
            "bytes=-17",
            forHTTPHeaderField: "Range")
        let (suffixData, suffixResponse) =
            try await session.data(for: suffixRequest)
        XCTAssertEqual(
            (suffixResponse as? HTTPURLResponse)?.statusCode,
            206)
        XCTAssertEqual(
            suffixData,
            expected.subdata(in: (expected.count - 17)..<expected.count))

        let openStart = expected.count - 13
        var openEndedRequest = URLRequest(url: url)
        openEndedRequest.timeoutInterval = 5
        openEndedRequest.setValue(
            "bytes=\(openStart)-",
            forHTTPHeaderField: "Range")
        let (openEndedData, openEndedResponse) =
            try await session.data(for: openEndedRequest)
        XCTAssertEqual(
            (openEndedResponse as? HTTPURLResponse)?.statusCode,
            206)
        XCTAssertEqual(
            openEndedData,
            expected.subdata(in: openStart..<expected.count))

        var fullHeadRequest = URLRequest(url: url)
        fullHeadRequest.httpMethod = "HEAD"
        fullHeadRequest.timeoutInterval = 5
        let (fullHeadData, fullHeadResponse) =
            try await session.data(for: fullHeadRequest)
        let fullHeadHTTP = try XCTUnwrap(
            fullHeadResponse as? HTTPURLResponse)
        XCTAssertEqual(fullHeadHTTP.statusCode, 200)
        XCTAssertTrue(fullHeadData.isEmpty)
        XCTAssertEqual(
            fullHeadHTTP.value(forHTTPHeaderField: "Content-Length"),
            String(expected.count))
        XCTAssertEqual(
            fullHeadHTTP.value(forHTTPHeaderField: "Accept-Ranges"),
            "bytes")

        var rangeHeadRequest = URLRequest(url: url)
        rangeHeadRequest.httpMethod = "HEAD"
        rangeHeadRequest.timeoutInterval = 5
        rangeHeadRequest.setValue(
            "bytes=4-11",
            forHTTPHeaderField: "Range")
        let (rangeHeadData, rangeHeadResponse) =
            try await session.data(for: rangeHeadRequest)
        let rangeHeadHTTP = try XCTUnwrap(
            rangeHeadResponse as? HTTPURLResponse)
        XCTAssertEqual(rangeHeadHTTP.statusCode, 206)
        XCTAssertTrue(rangeHeadData.isEmpty)
        XCTAssertEqual(
            rangeHeadHTTP.value(forHTTPHeaderField: "Content-Length"),
            "8")
        XCTAssertEqual(
            rangeHeadHTTP.value(forHTTPHeaderField: "Content-Range"),
            "bytes 4-11/\(expected.count)")
        XCTAssertEqual(
            rangeHeadHTTP.value(forHTTPHeaderField: "Accept-Ranges"),
            "bytes")

        for invalidRange in [
            "bytes=\(expected.count)-",
            "bytes=0-1,3-4",
        ] {
            var invalidRequest = URLRequest(url: url)
            invalidRequest.timeoutInterval = 5
            invalidRequest.setValue(
                invalidRange,
                forHTTPHeaderField: "Range")
            let (_, invalidResponse) =
                try await session.data(for: invalidRequest)
            let invalidHTTP = try XCTUnwrap(
                invalidResponse as? HTTPURLResponse)
            XCTAssertEqual(
                invalidHTTP.statusCode,
                416,
                invalidRange)
            XCTAssertEqual(
                invalidHTTP.value(
                    forHTTPHeaderField: "Content-Range"),
                "bytes */\(expected.count)")
            XCTAssertEqual(
                invalidHTTP.value(
                    forHTTPHeaderField: "Accept-Ranges"),
                "bytes")
        }
    }

    func testLoopbackPWABootstrapAndClaimAreAuthenticatedAndOneTime()
        async throws
    {
        let port = UInt16.random(in: 40_000...60_000)
        let ready = expectation(
            description: "PWA pairing listener is ready")
        let server = MobileDashboardHTTPServer(
            stateHandler: { state in
                if case .ready = state {
                    ready.fulfill()
                }
            },
            viewerCountHandler: { _ in })
        let accessToken = "test-only-access-token"
        server.start(port: port, accessToken: accessToken)
        await fulfillment(of: [ready], timeout: 5)
        defer {
            server.stop()
        }

        let configuration =
            URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(
            configuration: configuration)
        defer {
            session.invalidateAndCancel()
        }
        let baseURL = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)"))
        let bootstrapURL = baseURL
            .appendingPathComponent("api/v1/pwa/bootstrap")
        let claimURL = baseURL
            .appendingPathComponent("api/v1/pwa/claim")
        let manifestURL = baseURL
            .appendingPathComponent("manifest.webmanifest")

        var staticManifestRequest = URLRequest(url: manifestURL)
        staticManifestRequest.timeoutInterval = 5
        let (staticManifestData, staticManifestResponse) =
            try await session.data(for: staticManifestRequest)
        XCTAssertEqual(
            (staticManifestResponse as? HTTPURLResponse)?.statusCode,
            200)
        let staticManifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: staticManifestData)
                as? [String: Any])
        XCTAssertEqual(staticManifest["start_url"] as? String, "/")

        var wrongBearer = URLRequest(url: bootstrapURL)
        wrongBearer.httpMethod = "POST"
        wrongBearer.timeoutInterval = 5
        wrongBearer.setValue(
            "Bearer incorrect-test-token",
            forHTTPHeaderField: "Authorization")
        let (_, wrongResponse) = try await session.data(
            for: wrongBearer)
        XCTAssertEqual(
            (wrongResponse as? HTTPURLResponse)?.statusCode,
            401)

        var bootstrap = URLRequest(url: bootstrapURL)
        bootstrap.httpMethod = "POST"
        bootstrap.timeoutInterval = 5
        bootstrap.setValue(
            "Bearer \(accessToken)",
            forHTTPHeaderField: "Authorization")
        bootstrap.setValue(
            baseURL.absoluteString,
            forHTTPHeaderField: "Origin")
        let (bootstrapData, bootstrapResponse) =
            try await session.data(for: bootstrap)
        let bootstrapHTTP = try XCTUnwrap(
            bootstrapResponse as? HTTPURLResponse)
        XCTAssertEqual(bootstrapHTTP.statusCode, 200)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(
                with: bootstrapData) as? [String: String],
            ["status": "ready"])
        XCTAssertEqual(
            bootstrapHTTP.value(
                forHTTPHeaderField: "Cache-Control"),
            "no-store")
        XCTAssertTrue(
            bootstrapHTTP.value(
                forHTTPHeaderField:
                    "Content-Security-Policy"
            )?.contains("worker-src 'self'") == true)
        let setCookie = try XCTUnwrap(
            bootstrapHTTP.value(
                forHTTPHeaderField: "Set-Cookie"))
        XCTAssertTrue(setCookie.contains("HttpOnly"))
        XCTAssertTrue(setCookie.contains("SameSite=Strict"))
        XCTAssertTrue(setCookie.contains("Path=/"))
        XCTAssertTrue(
            setCookie.contains(
                MobileDashboardHTTPServer.pwaBootstrapCookieName))
        XCTAssertTrue(
            setCookie.contains(
                MobileDashboardHTTPServer.pwaInstallCookieName))
        XCTAssertTrue(
            setCookie.contains(
                "Max-Age=\(Int(MobileDashboardHTTPServer.pwaBootstrapLifetime))"))
        XCTAssertTrue(
            setCookie.contains(
                "Max-Age=\(Int(MobileDashboardHTTPServer.pwaInstallCredentialLifetime))"))
        XCTAssertFalse(
            setCookie.lowercased().contains("; secure"))
        XCTAssertFalse(setCookie.contains(accessToken))
        let bootstrapCookiePair = try XCTUnwrap(
            cookiePair(
                named: MobileDashboardHTTPServer
                    .pwaBootstrapCookieName,
                in: setCookie))
        let installCookiePair = try XCTUnwrap(
            cookiePair(
                named: MobileDashboardHTTPServer
                    .pwaInstallCookieName,
                in: setCookie))

        var installManifestRequest = URLRequest(url: manifestURL)
        installManifestRequest.timeoutInterval = 5
        installManifestRequest.setValue(
            installCookiePair,
            forHTTPHeaderField: "Cookie")
        let (installManifestData, installManifestResponse) =
            try await session.data(for: installManifestRequest)
        let installManifestHTTP = try XCTUnwrap(
            installManifestResponse as? HTTPURLResponse)
        XCTAssertEqual(installManifestHTTP.statusCode, 200)
        XCTAssertEqual(
            installManifestHTTP.value(
                forHTTPHeaderField: "Cache-Control"),
            "no-store")
        XCTAssertTrue(
            installManifestHTTP.value(
                forHTTPHeaderField: "Content-Security-Policy"
            )?.contains("default-src 'none'") == true)
        let installManifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: installManifestData)
                as? [String: Any])
        XCTAssertEqual(installManifest["id"] as? String, "/")
        XCTAssertEqual(installManifest["scope"] as? String, "/")
        let installStartURL = try XCTUnwrap(
            installManifest["start_url"] as? String)
        let installFragment = try XCTUnwrap(
            URLComponents(string: installStartURL)?.fragment)
        XCTAssertTrue(installFragment.hasPrefix("install=v1."))
        let installCredential = String(
            installFragment.dropFirst("install=".count))
        XCTAssertFalse(installCredential.contains(accessToken))
        XCTAssertFalse(installManifestData.range(of: Data(accessToken.utf8)) != nil)
        XCTAssertFalse(
            installStartURL.contains("?"),
            "Credentials belong in a fragment, never a query or request target.")

        var cookieBridgeClaim = URLRequest(url: claimURL)
        cookieBridgeClaim.httpMethod = "POST"
        cookieBridgeClaim.timeoutInterval = 5
        cookieBridgeClaim.setValue(
            installCookiePair,
            forHTTPHeaderField: "Cookie")
        cookieBridgeClaim.setValue(
            baseURL.absoluteString,
            forHTTPHeaderField: "Origin")
        let (cookieBridgeData, cookieBridgeResponse) =
            try await session.data(for: cookieBridgeClaim)
        XCTAssertEqual(
            (cookieBridgeResponse as? HTTPURLResponse)?.statusCode,
            200)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: cookieBridgeData)
                as? [String: String],
            ["token": accessToken])
        let (_, cookieBridgeReplayResponse) =
            try await session.data(for: cookieBridgeClaim)
        XCTAssertEqual(
            (cookieBridgeReplayResponse as? HTTPURLResponse)?.statusCode,
            200,
            "The copied install cookie is idempotent across root launches.")

        var standaloneClaim = URLRequest(url: claimURL)
        standaloneClaim.httpMethod = "POST"
        standaloneClaim.timeoutInterval = 5
        standaloneClaim.setValue(
            baseURL.absoluteString,
            forHTTPHeaderField: "Origin")
        standaloneClaim.setValue(
            "PWAInstall \(installCredential)",
            forHTTPHeaderField: "Authorization")
        let (standaloneData, standaloneResponse) =
            try await session.data(for: standaloneClaim)
        XCTAssertEqual(
            (standaloneResponse as? HTTPURLResponse)?.statusCode,
            200)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: standaloneData)
                as? [String: String],
            ["token": accessToken])
        let (_, standaloneReplayResponse) =
            try await session.data(for: standaloneClaim)
        XCTAssertEqual(
            (standaloneReplayResponse as? HTTPURLResponse)?.statusCode,
            200,
            "Repeated standalone launches are idempotent.")

        var claim = URLRequest(url: claimURL)
        claim.httpMethod = "POST"
        claim.timeoutInterval = 5
        claim.setValue(
            bootstrapCookiePair,
            forHTTPHeaderField: "Cookie")
        claim.setValue(
            baseURL.absoluteString,
            forHTTPHeaderField: "Origin")

        var crossOriginClaim = claim
        crossOriginClaim.setValue(
            "http://127.0.0.1:\(port + 1)",
            forHTTPHeaderField: "Origin")
        let (_, crossOriginResponse) =
            try await session.data(for: crossOriginClaim)
        XCTAssertEqual(
            (crossOriginResponse as? HTTPURLResponse)?
                .statusCode,
            403)

        let (claimData, claimResponse) =
            try await session.data(for: claim)
        let claimHTTP = try XCTUnwrap(
            claimResponse as? HTTPURLResponse)
        XCTAssertEqual(claimHTTP.statusCode, 200)
        XCTAssertEqual(
            claimHTTP.value(
                forHTTPHeaderField: "Cache-Control"),
            "no-store")
        XCTAssertTrue(
            claimHTTP.value(
                forHTTPHeaderField: "Set-Cookie"
            )?.contains("Max-Age=0") == true)
        let claimObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: claimData)
                as? [String: String])
        XCTAssertTrue(
            MobileDashboardHTTPServer.constantTimeEqual(
                claimObject["token"] ?? "",
                accessToken))

        let (_, replayResponse) =
            try await session.data(for: claim)
        let replayHTTP = try XCTUnwrap(
            replayResponse as? HTTPURLResponse)
        XCTAssertEqual(replayHTTP.statusCode, 401)
        XCTAssertTrue(
            replayHTTP.value(
                forHTTPHeaderField: "Set-Cookie"
            )?.contains("Max-Age=0") == true)

        var bootstrapRead = URLRequest(url: bootstrapURL)
        bootstrapRead.httpMethod = "GET"
        bootstrapRead.timeoutInterval = 5
        let (_, bootstrapReadResponse) =
            try await session.data(for: bootstrapRead)
        let bootstrapReadHTTP = try XCTUnwrap(
            bootstrapReadResponse as? HTTPURLResponse)
        XCTAssertEqual(bootstrapReadHTTP.statusCode, 405)
        XCTAssertEqual(
            bootstrapReadHTTP.value(
                forHTTPHeaderField: "Allow"),
            "POST")

        let iconURL = baseURL
            .appendingPathComponent("icon-192.png")
        var iconHead = URLRequest(url: iconURL)
        iconHead.httpMethod = "HEAD"
        iconHead.timeoutInterval = 5
        let (_, iconResponse) =
            try await session.data(for: iconHead)
        let iconHTTP = try XCTUnwrap(
            iconResponse as? HTTPURLResponse)
        XCTAssertEqual(iconHTTP.statusCode, 200)
        XCTAssertEqual(
            iconHTTP.value(
                forHTTPHeaderField: "Content-Type"),
            "image/png")
        XCTAssertGreaterThan(
            Int(
                iconHTTP.value(
                    forHTTPHeaderField: "Content-Length"
                ) ?? "0") ?? 0,
            100)
    }

    func testInstallCookieClaimIsStatelessAcrossServerReconstruction()
        async throws
    {
        let port = UInt16.random(in: 40_000...60_000)
        let accessToken = "restart-stable-master-token"
        let origin = "http://127.0.0.1:\(port)"
        let issuedAt = Date()
        let credential = try XCTUnwrap(
            MobileDashboardPWAInstallCredential.issue(
                accessToken: accessToken,
                origin: origin,
                issuedAt: issuedAt,
                installID: String(repeating: "R", count: 43)))

        // The credential is issued before this server object exists. A fresh
        // process can validate it from the persisted master token alone.
        let ready = expectation(description: "Reconstructed server is ready")
        let server = MobileDashboardHTTPServer(
            stateHandler: { state in
                if case .ready = state { ready.fulfill() }
            },
            viewerCountHandler: { _ in })
        server.start(port: port, accessToken: accessToken)
        await fulfillment(of: [ready], timeout: 5)
        defer { server.stop() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let claimURL = try XCTUnwrap(
            URL(string: "\(origin)/api/v1/pwa/claim"))
        var request = URLRequest(url: claimURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(
            "\(MobileDashboardHTTPServer.pwaInstallCookieName)=\(credential)",
            forHTTPHeaderField: "Cookie")
        let immutableRequest = request

        async let firstResult = session.data(for: immutableRequest)
        async let secondResult = session.data(for: immutableRequest)
        let concurrentResults = try await [firstResult, secondResult]
        for (data, response) in concurrentResults {
            XCTAssertEqual(
                (response as? HTTPURLResponse)?.statusCode,
                200)
            XCTAssertEqual(
                try JSONSerialization.jsonObject(with: data)
                    as? [String: String],
                ["token": accessToken])
        }

        let replacement = credential.last == "A" ? "B" : "A"
        var tamperedRequest = immutableRequest
        tamperedRequest.setValue(
            "\(MobileDashboardHTTPServer.pwaInstallCookieName)="
                + String(credential.dropLast()) + replacement,
            forHTTPHeaderField: "Cookie")
        let (_, tamperedResponse) =
            try await session.data(for: tamperedRequest)
        let tamperedHTTP = try XCTUnwrap(
            tamperedResponse as? HTTPURLResponse)
        XCTAssertEqual(
            tamperedHTTP.statusCode,
            401)
        XCTAssertTrue(
            tamperedHTTP.value(
                forHTTPHeaderField: "Set-Cookie"
            )?.contains(
                "\(MobileDashboardHTTPServer.pwaInstallCookieName)=;"
                    + " HttpOnly; SameSite=Strict; Path=/; Max-Age=0")
                == true)

        let otherOriginCredential = try XCTUnwrap(
            MobileDashboardPWAInstallCredential.issue(
                accessToken: accessToken,
                origin: "http://192.168.1.20:\(port)",
                issuedAt: issuedAt,
                installID: String(repeating: "H", count: 43)))
        var wrongHostRequest = immutableRequest
        wrongHostRequest.setValue(
            "\(MobileDashboardHTTPServer.pwaInstallCookieName)="
                + otherOriginCredential,
            forHTTPHeaderField: "Cookie")
        let (_, wrongHostResponse) =
            try await session.data(for: wrongHostRequest)
        XCTAssertEqual(
            (wrongHostResponse as? HTTPURLResponse)?.statusCode,
            401)

        var crossOriginRequest = immutableRequest
        crossOriginRequest.setValue(
            "http://127.0.0.1:\(port + 1)",
            forHTTPHeaderField: "Origin")
        let (_, crossOriginResponse) =
            try await session.data(for: crossOriginRequest)
        XCTAssertEqual(
            (crossOriginResponse as? HTTPURLResponse)?.statusCode,
            403)
    }

    func testGeneratedAccessTokensAreStrongURLSafeValues() throws {
        let tokens = try (0..<32).map { _ in
            try XCTUnwrap(
                MobileDashboardService.generateAccessToken())
        }

        XCTAssertEqual(Set(tokens).count, tokens.count)
        for token in tokens {
            XCTAssertEqual(token.utf8.count, 43)
            XCTAssertNotNil(
                token.range(
                    of: #"^[A-Za-z0-9_-]{43}$"#,
                    options: .regularExpression))
            XCTAssertFalse(token.contains("="))
            XCTAssertFalse(token.contains("+"))
            XCTAssertFalse(token.contains("/"))
        }
    }

    func testGeneratedManualPairingCodesAreEightASCIIDigits() throws {
        var values = Set<String>()
        for _ in 0..<64 {
            let code = try XCTUnwrap(
                MobileDashboardService.generateManualPairingCode())
            XCTAssertEqual(code.utf8.count, 8)
            XCTAssertTrue(
                code.utf8.allSatisfy({ (48...57).contains($0) }))
            values.insert(code)
        }
        XCTAssertGreaterThan(values.count, 60)
    }

    @MainActor
    func testMobileDashboardIsDefaultOff() throws {
        let suiteName = "MobileDashboardSecurityTests.\(UUID())"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let service = MobileDashboardService(
            defaults: defaults,
            snapshotProvider: { _, _, _, _ in
                fatalError("A disabled service must not request a snapshot.")
            },
            onViewerActivityChanged: { _ in
                XCTFail(
                    "A disabled service must not activate viewer mode.")
            },
            refreshRoute: {
                XCTFail("A disabled service must not refresh routes.")
            },
            testRoutes: {
                XCTFail("A disabled service must not test routes.")
            })

        service.startIfEnabled()

        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(service.state, .off)
        XCTAssertEqual(service.viewerCount, 0)
        XCTAssertNil(service.accessURLString)
    }

    @MainActor
    func testIdleBlackoutMarqueeDefaultsOnForFreshAndUpgradedInstalls()
        throws
    {
        let suiteName = "MobileDashboardIdleBlackoutDefaults.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var service: MobileDashboardService? = makeDisabledService(
            defaults: defaults)
        XCTAssertTrue(try XCTUnwrap(service).idleBlackoutMarqueeEnabled)
        XCTAssertNil(
            defaults.object(
                forKey: "mobileDashboardIdleBlackoutMarqueeEnabled"),
            "Reading the safe default must not make it look user-selected.")

        service = nil
        defaults.set(
            false,
            forKey: "mobileDashboardOLEDProtectionEnabled")
        service = makeDisabledService(defaults: defaults)
        XCTAssertTrue(
            try XCTUnwrap(service).idleBlackoutMarqueeEnabled,
            "An upgraded install with no new key must adopt blackout.")
    }

    @MainActor
    func testIdleBlackoutMarqueeRoundTripsAndInvalidStorageFailsOn()
        throws
    {
        let suiteName = "MobileDashboardIdleBlackoutStorage.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var service: MobileDashboardService? = makeDisabledService(
            defaults: defaults)
        try XCTUnwrap(service).idleBlackoutMarqueeEnabled = false
        XCTAssertEqual(
            defaults.object(
                forKey: "mobileDashboardIdleBlackoutMarqueeEnabled")
                as? Bool,
            false)

        service = nil
        service = makeDisabledService(defaults: defaults)
        XCTAssertFalse(try XCTUnwrap(service).idleBlackoutMarqueeEnabled)
        try XCTUnwrap(service).idleBlackoutMarqueeEnabled = true

        service = nil
        defaults.set(
            "not-a-boolean",
            forKey: "mobileDashboardIdleBlackoutMarqueeEnabled")
        service = makeDisabledService(defaults: defaults)
        XCTAssertTrue(
            try XCTUnwrap(service).idleBlackoutMarqueeEnabled,
            "Malformed preference data must fail closed to blackout on.")
    }

    @MainActor
    func testAccountMaskingDefaultsOnForFreshAndUpgradedInstalls()
        throws
    {
        let suiteName = "MobileDashboardAccountMaskDefaults.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var service: MobileDashboardService? = makeDisabledService(
            defaults: defaults)
        XCTAssertTrue(try XCTUnwrap(service).masksAccountNames)
        XCTAssertNil(
            defaults.object(forKey: "mobileDashboardMasksAccountNames"))

        service = nil
        defaults.set(
            true,
            forKey: "mobileDashboardShowsFullAccountNames")
        service = makeDisabledService(defaults: defaults)
        XCTAssertTrue(
            try XCTUnwrap(service).masksAccountNames,
            "The removed show-full opt-in must not migrate into disclosure.")
        XCTAssertNil(
            defaults.object(forKey: "mobileDashboardMasksAccountNames"))
    }

    @MainActor
    func testAccountMaskingRoundTripsAndInvalidStorageFailsOn() throws {
        let suiteName = "MobileDashboardAccountMaskStorage.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var service: MobileDashboardService? = makeDisabledService(
            defaults: defaults)
        try XCTUnwrap(service).masksAccountNames = false
        XCTAssertEqual(
            defaults.object(forKey: "mobileDashboardMasksAccountNames")
                as? Bool,
            false)

        service = nil
        service = makeDisabledService(defaults: defaults)
        XCTAssertFalse(try XCTUnwrap(service).masksAccountNames)
        try XCTUnwrap(service).masksAccountNames = true

        service = nil
        defaults.set(
            "not-a-boolean",
            forKey: "mobileDashboardMasksAccountNames")
        service = makeDisabledService(defaults: defaults)
        XCTAssertTrue(
            try XCTUnwrap(service).masksAccountNames,
            "Malformed preference data must fail closed to masking on.")
    }

    @MainActor
    func testPairingCodeIsOptInForFreshAndUpgradedInstalls() throws {
        let suiteName = "MobileDashboardPairingDefaults.\(UUID())"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let tokenStore = MobileDashboardRecordingTokenStore()

        var service: MobileDashboardService? = MobileDashboardService(
            defaults: defaults,
            accessTokenStore: tokenStore,
            snapshotProvider: { _, _, _, _ in
                fatalError("The disabled service must not snapshot.")
            },
            onViewerActivityChanged: { _ in },
            refreshRoute: {},
            testRoutes: {})
        XCTAssertFalse(try XCTUnwrap(service).requiresPairingCode)
        XCTAssertNil(
            defaults.object(
                forKey: "mobileDashboardRequiresPairingCode"),
            "Reading the fresh default must not silently turn it into opt-in.")

        service = nil
        defaults.set(true, forKey: "mobileDashboardEnabled")
        service = MobileDashboardService(
            defaults: defaults,
            accessTokenStore: tokenStore,
            snapshotProvider: { _, _, _, _ in
                fatalError("Initialization must not snapshot.")
            },
            onViewerActivityChanged: { _ in },
            refreshRoute: {},
            testRoutes: {})
        XCTAssertFalse(
            try XCTUnwrap(service).requiresPairingCode,
            "An upgraded install without the new key must also adopt off.")

        defaults.set(false, forKey: "mobileDashboardEnabled")
        XCTAssertTrue(
            try XCTUnwrap(service).setRequiresPairingCode(true))
        XCTAssertTrue(try XCTUnwrap(service).requiresPairingCode)
        XCTAssertEqual(
            defaults.object(
                forKey: "mobileDashboardRequiresPairingCode") as? Bool,
            true)
        XCTAssertNil(try XCTUnwrap(service).manualPairingCode)
        XCTAssertEqual(tokenStore.loadCallCount, 0)
        XCTAssertEqual(tokenStore.saveCallCount, 0)

        service = MobileDashboardService(
            defaults: defaults,
            accessTokenStore: tokenStore,
            snapshotProvider: { _, _, _, _ in
                fatalError("The disabled service must not snapshot.")
            },
            onViewerActivityChanged: { _ in },
            refreshRoute: {},
            testRoutes: {})
        XCTAssertTrue(
            try XCTUnwrap(service).requiresPairingCode,
            "Only an explicit opt-in is retained.")
    }

    func testModelSelectionKeyNormalizesAndMatchesWithoutCompositeID()
        throws
    {
        let model = makeQuotaModel(
            provider: .codex,
            account: " Alice@Example.COM ",
            name: " Weekly ")
        let key = MobileDashboardModelSelectionKey(model: model)

        XCTAssertEqual(key.version, 1)
        XCTAssertEqual(key.providerRaw, "codex")
        XCTAssertEqual(key.normalizedAccount, "alice@example.com")
        XCTAssertEqual(key.normalizedModel, "weekly")
        XCTAssertTrue(key.matches(model))

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(key))
                as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            [
                "version",
                "providerRaw",
                "normalizedAccount",
                "normalizedModel",
            ])
        XCTAssertNil(object["id"])
    }

    @MainActor
    func testModelSelectionInitializesLaterAndPersistsOneOrTwoModels()
        throws
    {
        let suiteName = "MobileDashboardSecurityTests.\(UUID())"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let service = makeDisabledService(defaults: defaults)
        let models = [
            makeQuotaModel(
                provider: .codex,
                account: "one@example.com",
                name: "5h"),
            makeQuotaModel(
                provider: .codex,
                account: "one@example.com",
                name: "Weekly"),
            makeQuotaModel(
                provider: .miniMax,
                account: nil,
                name: "MiniMax"),
        ]

        service.initializeModelSelectionIfNeeded(candidates: [])
        XCTAssertTrue(service.selectedModelKeys.isEmpty)

        service.initializeModelSelectionIfNeeded(candidates: models)
        XCTAssertEqual(
            service.selectedModelKeys,
            Array(
                models.prefix(2).map(
                    \.mobileDashboardSelectionKey)))
        XCTAssertFalse(service.setSelectedModelKeys([]))
        XCTAssertFalse(
            service.setSelectedModelKeys(
                models.map(\.mobileDashboardSelectionKey)))

        let orphan = models[2].mobileDashboardSelectionKey
        XCTAssertTrue(service.setSelectedModelKeys([orphan]))
        let restored = makeDisabledService(defaults: defaults)
        XCTAssertEqual(restored.selectedModelKeys, [orphan])

        restored.initializeModelSelectionIfNeeded(
            candidates: Array(models.prefix(2)))
        XCTAssertEqual(
            restored.selectedModelKeys,
            [orphan],
            "A temporarily unavailable selection must not be replaced.")
    }

    @MainActor
    func testModelSelectionToggleEnforcesMinimumAndMaximum() throws {
        let suiteName = "MobileDashboardSecurityTests.\(UUID())"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let service = makeDisabledService(defaults: defaults)
        let keys = (0..<3).map {
            makeQuotaModel(
                provider: .codex,
                account: "account",
                name: "model-\($0)")
                .mobileDashboardSelectionKey
        }

        service.initializeModelSelectionIfNeeded(
            candidates: [
                makeQuotaModel(
                    provider: .codex,
                    account: "account",
                    name: "model-0"),
            ])
        XCTAssertFalse(service.toggleModelSelection(keys[0]))
        XCTAssertTrue(service.toggleModelSelection(keys[1]))
        XCTAssertFalse(service.toggleModelSelection(keys[2]))
        XCTAssertTrue(service.toggleModelSelection(keys[0]))
        XCTAssertEqual(service.selectedModelKeys, [keys[1]])
    }

    @MainActor
    func testDefaultSelectionPrioritizesCurveModelsInDisplayOrder()
        throws
    {
        let suiteName = "MobileDashboardSecurityTests.\(UUID())"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let service = makeDisabledService(defaults: defaults)
        let nonCurveFirst = makeQuotaModel(
            provider: .codex,
            account: "one@example.com",
            name: "Daily",
            duration: 2 * 86_400)
        let fiveHourCurve = makeQuotaModel(
            provider: .codex,
            account: "one@example.com",
            name: "5h",
            duration: 5 * 3_600)
        let weeklyCurve = makeQuotaModel(
            provider: .codex,
            account: "two@example.com",
            name: "Weekly",
            duration: 7 * 86_400)
        let nonCurveLast = makeQuotaModel(
            provider: .codex,
            account: "one@example.com",
            name: "Monthly",
            duration: 30 * 86_400)

        service.initializeModelSelectionIfNeeded(
            candidates: [
                nonCurveFirst,
                fiveHourCurve,
                weeklyCurve,
                nonCurveLast,
            ])

        XCTAssertEqual(
            service.selectedModelKeys,
            [
                fiveHourCurve.mobileDashboardSelectionKey,
                weeklyCurve.mobileDashboardSelectionKey,
            ])
    }

    @MainActor
    func testEncodedSnapshotsContainOnlyTheSelectedAccountRepresentation()
        throws
    {
        let suiteName = "MobileDashboardEncodedAccountPrivacy.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MobileDashboardEncodedAccountPrivacy-\(UUID())",
                isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        let rawAccount = "HOSTILE_RAW_ACCOUNT_SENTINEL@example.com"
        let maskedAccount = "H•••@example.com"
        let model = makeQuotaModel(
            provider: .codex,
            account: rawAccount,
            name: "Weekly")
        let viewModel = UsageViewModel()
        let usage = UsageData(
            provider: .codex,
            remains: 1,
            total: 1,
            timestamp: Date(),
            models: [model],
            subscribeTitle: nil,
            subscribeEndTime: nil)
        viewModel.providerUsageData = [.codex: usage]
        viewModel.usageData = usage
        let protection = CodexSleepProtectionCoordinator(
            defaults: defaults,
            localActivityProvider: nil,
            closedLidModeManager: ClosedLidModeManager(
                defaults: defaults,
                bundle: .main))
        let connectivity = CodexConnectivityMonitor(
            checker: CodexConnectivityChecker { _ in false })
        let route = ClashRouteViewModel(defaults: defaults)
        let connections = ClashConnectionViewModel(
            historyStore: ClashConnectionHistoryStore(
                directoryURL: directory))

        func encode(masksAccountNames: Bool) throws
            -> (data: Data, model: [String: Any])
        {
            let snapshot = MobileDashboardSnapshotBuilder.make(
                usageViewModel: viewModel,
                connectivityMonitor: connectivity,
                protectionCoordinator: protection,
                routeViewModel: route,
                connectionViewModel: connections,
                masksAccountNames: masksAccountNames,
                selectedModelKeys: [model.mobileDashboardSelectionKey],
                lastRouteTestedAt: nil)
            let data = try JSONEncoder().encode(snapshot)
            let root = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data)
                    as? [String: Any])
            let quota = try XCTUnwrap(root["quota"] as? [String: Any])
            let providers = try XCTUnwrap(
                quota["providers"] as? [[String: Any]])
            let provider = try XCTUnwrap(providers.first)
            let models = try XCTUnwrap(
                provider["models"] as? [[String: Any]])
            return (data, try XCTUnwrap(models.first))
        }

        let masked = try encode(masksAccountNames: true)
        let maskedJSON = String(decoding: masked.data, as: UTF8.self)
        XCTAssertEqual(masked.model["accountName"] as? String, maskedAccount)
        XCTAssertFalse(maskedJSON.contains(rawAccount))
        XCTAssertEqual(
            maskedJSON.components(separatedBy: "\"accountName\"").count - 1,
            1,
            "One selected model must encode one accountName field only.")

        let unmasked = try encode(masksAccountNames: false)
        let unmaskedJSON = String(decoding: unmasked.data, as: UTF8.self)
        XCTAssertEqual(unmasked.model["accountName"] as? String, rawAccount)
        XCTAssertFalse(unmaskedJSON.contains(maskedAccount))
        XCTAssertEqual(
            unmaskedJSON.components(separatedBy: "\"accountName\"").count - 1,
            1,
            "Raw and masked account fields must never coexist.")
    }

    @MainActor
    func testSnapshotBuilderFiltersBeforeEncodingAndUsesSelectedPrimary()
        throws
    {
        let suiteName = "MobileDashboardSecurityTests.\(UUID())"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MobileDashboardSecurityTests-\(UUID())",
                isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let first = makeQuotaModel(
            provider: .codex,
            account: "first@example.com",
            name: "5h",
            remainingPercent: 80)
        let selected = makeQuotaModel(
            provider: .codex,
            account: "selected@example.com",
            name: "Weekly",
            remainingPercent: 35,
            duration: 7 * 86_400)
        let credits = makeQuotaModel(
            provider: .codex,
            account: "credits@example.com",
            name: "Credits",
            remainingPercent: 25,
            duration: 2 * 3_600,
            progressBarPercentOverride: 25)
        let menuWeekly = makeQuotaModel(
            provider: .codex,
            account: "first@example.com",
            name: "Weekly",
            remainingPercent: 35,
            duration: 7 * 86_400)
        let viewModel = UsageViewModel()
        viewModel.providerUsageData = [
            .codex: UsageData(
                provider: .codex,
                remains: 2,
                total: 2,
                timestamp: Date(),
                models: [first, selected, credits],
                subscribeTitle: nil,
                subscribeEndTime: nil),
        ]
        viewModel.usageData = UsageData(
            provider: .codex,
            remains: 2,
            total: 2,
            timestamp: Date(),
            models: [first, menuWeekly],
            subscribeTitle: nil,
            subscribeEndTime: nil)
        let closedLidManager = ClosedLidModeManager(
            defaults: defaults,
            bundle: .main)
        let protection = CodexSleepProtectionCoordinator(
            defaults: defaults,
            localActivityProvider: nil,
            closedLidModeManager: closedLidManager)
        let snapshot = MobileDashboardSnapshotBuilder.make(
            usageViewModel: viewModel,
            connectivityMonitor: CodexConnectivityMonitor(
                checker: CodexConnectivityChecker { _ in false }),
            protectionCoordinator: protection,
            routeViewModel: ClashRouteViewModel(defaults: defaults),
            connectionViewModel: ClashConnectionViewModel(
                historyStore: ClashConnectionHistoryStore(
                    directoryURL: directory)),
            masksAccountNames: true,
            selectedModelKeys: [
                credits.mobileDashboardSelectionKey,
                selected.mobileDashboardSelectionKey,
            ],
            lastRouteTestedAt: nil)

        XCTAssertEqual(snapshot.schemaVersion, 3)
        XCTAssertEqual(snapshot.quota.primaryRemainingPercent, 25)
        XCTAssertEqual(snapshot.quota.providers.count, 1)
        XCTAssertEqual(
            snapshot.quota.providers[0].models.map(\.modelName),
            ["Weekly", "Credits"])
        XCTAssertEqual(
            snapshot.quota.providers[0].models[0].accountName,
            "s•••@example.com")
        let weeklySnapshot = snapshot.quota.providers[0].models[0]
        XCTAssertEqual(weeklySnapshot.displayOrder, 1)
        XCTAssertFalse(weeklySnapshot.isPrimary)
        XCTAssertTrue(weeklySnapshot.isCurrentIntervalPercentMode)
        XCTAssertFalse(weeklySnapshot.usesReverseProgressTint)
        XCTAssertTrue(
            weeklySnapshot.rendersAreaChart,
            "The native selector promotes an account's Weekly fallback.")
        XCTAssertTrue(weeklySnapshot.hasCurrentIntervalPace)
        XCTAssertNotNil(weeklySnapshot.paceStage)
        XCTAssertNotNil(weeklySnapshot.paceGuideTone)
        XCTAssertNotNil(
            weeklySnapshot.paceGuideExpectedUsedPercent)
        XCTAssertNotNil(
            weeklySnapshot.paceGuideExpectedRemaining)
        XCTAssertNotNil(weeklySnapshot.startsAt)
        XCTAssertNotNil(weeklySnapshot.resetsAt)
        let creditsSnapshot = snapshot.quota.providers[0].models[1]
        XCTAssertEqual(creditsSnapshot.displayOrder, 0)
        XCTAssertTrue(creditsSnapshot.isPrimary)
        XCTAssertTrue(creditsSnapshot.usesReverseProgressTint)
        XCTAssertTrue(creditsSnapshot.rendersAreaChart)
        XCTAssertFalse(creditsSnapshot.hasCurrentIntervalPace)
        XCTAssertNil(creditsSnapshot.paceStage)
        XCTAssertNil(creditsSnapshot.paceGuideTone)
        XCTAssertFalse(creditsSnapshot.paceGuideShowsMarker)
        XCTAssertEqual(
            snapshot.quota.warningThresholdPercent,
            viewModel.effectiveWarningThreshold > 0
                ? viewModel.effectiveWarningThreshold
                : nil)
        XCTAssertEqual(snapshot.menuBar.state, "ready")
        XCTAssertEqual(snapshot.menuBar.providerID, "codex")
        XCTAssertEqual(snapshot.menuBar.modelName, "5h")
        XCTAssertEqual(snapshot.menuBar.remainingPercent, 80)
        XCTAssertEqual(snapshot.menuBar.ringPercent, 35)
        XCTAssertEqual(
            snapshot.menuBar.appearance,
            viewModel.menuBarAppearance.rawValue)
        XCTAssertEqual(
            snapshot.menuBar.paceDisplayMode,
            viewModel.menuBarPaceDisplayMode.rawValue)
        XCTAssertFalse(snapshot.protection.hasActiveTasks)
    }

    func testGeneratedTimestampDoesNotDefeatSnapshotDeduplication() {
        let first = snapshot(
            generatedAt: Date(timeIntervalSince1970: 1_000),
            connectivity: "reachable")
        let second = snapshot(
            generatedAt: Date(timeIntervalSince1970: 2_000),
            connectivity: "reachable")
        let changed = snapshot(
            generatedAt: Date(timeIntervalSince1970: 2_000),
            connectivity: "unreachable")

        XCTAssertTrue(first.hasSameContent(as: second))
        XCTAssertFalse(first.hasSameContent(as: changed))
    }

    func testMobileSamplesAreDeterministicallyDownsampledWithEndpoints() {
        let input = Array(0..<10_000)
        let first = MobileDashboardDownsampling.equidistant(
            input,
            maximumCount: 240)
        let second = MobileDashboardDownsampling.equidistant(
            input,
            maximumCount: 240)

        XCTAssertEqual(first.count, 240)
        XCTAssertEqual(first.first, input.first)
        XCTAssertEqual(first.last, input.last)
        XCTAssertEqual(first, second)
        XCTAssertEqual(Set(first).count, first.count)
        XCTAssertEqual(first, first.sorted())
    }

    func testMobileDownsamplingKeepsSmallInputsAndHonorsEdgeLimits() {
        let input = [10, 20, 30]

        XCTAssertEqual(
            MobileDashboardDownsampling.equidistant(
                input,
                maximumCount: 3),
            input)
        XCTAssertEqual(
            MobileDashboardDownsampling.equidistant(
                input,
                maximumCount: 10),
            input)
        XCTAssertEqual(
            MobileDashboardDownsampling.equidistant(
                input,
                maximumCount: 2),
            [10, 30])
        XCTAssertEqual(
            MobileDashboardDownsampling.equidistant(
                input,
                maximumCount: 1),
            [10])
        XCTAssertEqual(
            MobileDashboardDownsampling.equidistant(
                input,
                maximumCount: 0),
            [])
    }

    func testActiveConnectionPayloadIsBoundedAndKeepsSourceOrder() {
        let input = Array(0..<150)
        let bounded = MobileDashboardPayloadLimits
            .boundedActiveConnections(input)

        XCTAssertEqual(
            bounded.count,
            MobileDashboardPayloadLimits.maximumActiveConnections)
        XCTAssertEqual(bounded, Array(0..<100))
        XCTAssertEqual(
            MobileDashboardPayloadLimits
                .boundedActiveConnections([3, 2, 1]),
            [3, 2, 1])
    }

    func testLongestActiveDurationUsesAllCurrentConnectionsBeforeBounding()
        throws
    {
        let connections = (0..<150).map { index in
            ClashActiveConnection(
                id: "connection-\(index)",
                host: "api.openai.com",
                process: nil,
                network: "tcp",
                chains: [],
                startedAt: nil,
                duration: TimeInterval(index),
                uploadSpeed: 0,
                downloadSpeed: 0)
        }

        XCTAssertEqual(
            MobileDashboardPayloadLimits
                .longestActiveDuration(connections),
            149)
        XCTAssertEqual(
            MobileDashboardPayloadLimits.longestActiveDuration(
                MobileDashboardPayloadLimits
                    .boundedActiveConnections(connections)),
            99,
            "The first 100-item display payload is not the full metric source.")
        XCTAssertNil(
            MobileDashboardPayloadLimits.longestActiveDuration([]))

        let snapshot = MobileConnectionsSnapshot(
            state: "ready",
            stateDetail: nil,
            observedAt: Date(timeIntervalSince1970: 1_000),
            clientName: nil,
            isLive: true,
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 0,
            activeCount: connections.count,
            longestActiveDuration: 149,
            history: [],
            active: [])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(snapshot))
                as? [String: Any])
        XCTAssertEqual(
            object["longestActiveDuration"] as? Double,
            149)
        XCTAssertEqual(object["activeCount"] as? Int, 150)
        XCTAssertEqual((object["history"] as? [Any])?.count, 0)
    }

    func testConnectionAgePayloadIsAnonymousSanitizedAndBounded() {
        let input = [-3, 120, .nan, .infinity]
            + (0..<150).map(TimeInterval.init)
        let bounded = MobileDashboardPayloadLimits
            .boundedConnectionAges(input)

        XCTAssertEqual(
            bounded.count,
            MobileDashboardPayloadLimits
                .maximumConnectionAgesPerSample)
        XCTAssertEqual(Array(bounded.prefix(2)), [0, 120])
        XCTAssertTrue(bounded.allSatisfy { $0.isFinite && $0 >= 0 })

        let sample = MobileConnectionHistorySnapshot(
            timestamp: Date(timeIntervalSince1970: 1_000),
            connectionCount: bounded.count,
            oldestConnectionAge: bounded.max() ?? 0,
            connectionAges: bounded)
        let data = try? JSONEncoder().encode(sample)
        let json = data.map { String(decoding: $0, as: UTF8.self) }
        XCTAssertNotNil(data)
        XCTAssertFalse(json?.contains("host") == true)
        XCTAssertFalse(json?.contains("process") == true)
        XCTAssertFalse(json?.contains("route") == true)
    }

    func testEveryNewViewerInvalidatesSnapshotForImmediateFirstState() {
        XCTAssertTrue(
            MobileDashboardViewerBroadcastPolicy
                .shouldInvalidateSnapshot(
                    previousCount: 0,
                    newCount: 1))
        XCTAssertTrue(
            MobileDashboardViewerBroadcastPolicy
                .shouldInvalidateSnapshot(
                    previousCount: 1,
                    newCount: 2))
        XCTAssertFalse(
            MobileDashboardViewerBroadcastPolicy
                .shouldInvalidateSnapshot(
                    previousCount: 2,
                    newCount: 1))
        XCTAssertFalse(
            MobileDashboardViewerBroadcastPolicy
                .shouldInvalidateSnapshot(
                    previousCount: 1,
                    newCount: 0))
        XCTAssertFalse(
            MobileDashboardViewerBroadcastPolicy
                .shouldInvalidateSnapshot(
                    previousCount: 0,
                    newCount: 0))
    }

    @MainActor
    func testLiveUpdateOwnerLeaseSurvivesAnotherOwnerClosing() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MobileDashboardSecurityTests-\(UUID())",
                isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let viewModel = ClashConnectionViewModel(
            historyStore: ClashConnectionHistoryStore(
                directoryURL: directory))
        defer {
            viewModel.stop()
        }

        viewModel.beginLiveUpdates(owner: "popover")
        viewModel.beginLiveUpdates(
            owner: MobileDashboardService.liveUpdateOwner)
        XCTAssertTrue(viewModel.isLive)

        viewModel.endLiveUpdates(owner: "popover")
        XCTAssertTrue(
            viewModel.isLive,
            "The mobile viewer still owns the live update lease.")

        viewModel.endLiveUpdates(
            owner: MobileDashboardService.liveUpdateOwner)
        XCTAssertFalse(viewModel.isLive)
    }

    private func snapshot(
        generatedAt: Date,
        connectivity: String,
        activitySummary: MobileActivitySummarySnapshot =
            MobileActivitySummarySnapshot(
                state: "idle",
                activeTaskCount: 0,
                oldestStartedAt: nil,
                elapsedSeconds: nil,
                lastActivityAt: nil,
                phase: "unknown",
                toolCategory: nil,
                toolStatus: nil,
                progressLines: nil,
                recentEvents: [])
    ) -> MobileDashboardSnapshot {
        MobileDashboardSnapshot(
            schemaVersion: 3,
            generatedAt: generatedAt,
            language: "en",
            macName: "Test Mac",
            appVersion: "1.0",
            connectivity: connectivity,
            menuBar: MobileMenuBarQuotaSnapshot(
                state: "ready",
                providerID: "codex",
                modelName: "Weekly",
                remainingPercent: 50,
                ringPercent: 50,
                paceDeltaPercent: 0,
                resetsAt: nil,
                isLowQuota: false,
                appearance: "compactRing",
                paceDisplayMode: "staged"),
            quota: MobileQuotaSnapshot(
                state: "ready",
                lastRefreshAt: nil,
                primaryRemainingPercent: 50,
                warningThresholdPercent: 20,
                errors: [],
                providers: []),
            activitySummary: activitySummary,
            protection: MobileProtectionSnapshot(
                isEnabled: false,
                activeTaskCount: 0,
                hasActiveTasks: false,
                status: "idle",
                statusDetail: nil,
                keepDisplayAwake: false,
                keepDisplayAwakeEffective: false,
                preventScreenSaver: false,
                preventScreenSaverEffective: false,
                hookStatus: "installed",
                hookActionRequired: false,
                closedLidEnabled: false,
                closedLidStatus: "disabled",
                closedLidDetail: nil,
                closedLidActionRequired: false,
                lastActivityAt: nil),
            route: MobileRouteSnapshot(
                state: "idle",
                groupName: nil,
                selectedRouteName: nil,
                selectedRouteType: nil,
                selectedRouteDelay: nil,
                clientName: nil,
                autoRecoveryEnabled: false,
                isSpeedTesting: false,
                statusMessage: nil,
                lastTestedAt: nil,
                recentSwitches: []),
            connections: MobileConnectionsSnapshot(
                state: "idle",
                stateDetail: nil,
                observedAt: nil,
                clientName: nil,
                isLive: false,
                uploadBytesPerSecond: 0,
                downloadBytesPerSecond: 0,
                activeCount: 0,
                longestActiveDuration: nil,
                history: [],
                active: []))
    }

    private func topLevelMP4BoxTypes(in data: Data) -> [String] {
        let bytes = [UInt8](data)
        var types: [String] = []
        var offset = 0

        while offset <= bytes.count - 8 {
            let shortSize = UInt64(bytes[offset]) << 24
                | UInt64(bytes[offset + 1]) << 16
                | UInt64(bytes[offset + 2]) << 8
                | UInt64(bytes[offset + 3])
            let type = String(
                bytes: bytes[(offset + 4)..<(offset + 8)],
                encoding: .ascii)
            var headerSize = 8
            var boxSize = shortSize
            if shortSize == 1 {
                guard offset <= bytes.count - 16 else { break }
                headerSize = 16
                boxSize = 0
                for byte in bytes[(offset + 8)..<(offset + 16)] {
                    boxSize = (boxSize << 8) | UInt64(byte)
                }
            } else if shortSize == 0 {
                boxSize = UInt64(bytes.count - offset)
            }
            guard let intBoxSize = Int(exactly: boxSize),
                  intBoxSize >= headerSize,
                  intBoxSize <= bytes.count - offset else {
                break
            }
            if let type {
                types.append(type)
            }
            offset += intBoxSize
        }
        return types
    }

    private func cookiePair(
        named name: String,
        in setCookieHeader: String
    ) -> String? {
        guard let start = setCookieHeader.range(of: "\(name)=") else {
            return nil
        }
        let suffix = setCookieHeader[start.lowerBound...]
        let end = suffix.firstIndex(of: ";") ?? suffix.endIndex
        return String(suffix[..<end])
    }

    @MainActor
    private func makeDisabledService(
        defaults: UserDefaults
    ) -> MobileDashboardService {
        MobileDashboardService(
            defaults: defaults,
            snapshotProvider: { _, _, _, _ in
                fatalError(
                    "A disabled service must not request a snapshot.")
            },
            onViewerActivityChanged: { _ in },
            refreshRoute: {},
            testRoutes: {})
    }

    private func activityObject(
        _ activity: MobileActivitySummarySnapshot
    ) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(activity))
                as? [String: Any])
    }

    private func makeQuotaModel(
        provider: UsageProvider,
        account: String?,
        name: String,
        remainingPercent: Int = 50,
        duration: TimeInterval = 2 * 3_600,
        progressBarPercentOverride: Double? = nil
    ) -> ModelUsageData {
        ModelUsageData(
            provider: provider,
            accountName: account,
            modelName: name,
            currentIntervalTotal: 100,
            currentIntervalUsed: remainingPercent,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: 3_600_000,
            startTime: Date().addingTimeInterval(-duration / 2),
            endTime: Date().addingTimeInterval(duration / 2),
            weeklyStartTime: nil,
            weeklyEndTime: nil,
            valueSuffix: "%",
            detailText: nil,
            currentIntervalRemainingPercent: remainingPercent,
            weeklyRemainingPercent: nil,
            progressBarPercentOverride: progressBarPercentOverride,
            progressBarRightText: nil,
            sampledAt: nil)
    }
}

private final class MobileDashboardRecordingTokenStore:
    MobileDashboardAccessTokenStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var _loadCallCount = 0
    private var _saveCallCount = 0

    var loadCallCount: Int {
        lock.withLock { _loadCallCount }
    }

    var saveCallCount: Int {
        lock.withLock { _saveCallCount }
    }

    func loadMobileDashboardAccessToken() async
        -> MobileDashboardAccessTokenLoadResult
    {
        lock.withLock { _loadCallCount += 1 }
        return .notFound
    }

    func saveMobileDashboardAccessToken(_ token: String) -> Bool {
        lock.withLock { _saveCallCount += 1 }
        return true
    }
}

private struct MobileDashboardSensitiveTestError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}
