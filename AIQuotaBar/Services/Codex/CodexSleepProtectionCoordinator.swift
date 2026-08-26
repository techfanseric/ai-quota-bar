import AppKit
import Foundation
import OSLog

enum CodexSleepProtectionStatus: Equatable {
    case idle
    case active
    case failed(String)
}

enum CodexActivitySummaryState: String, Equatable {
    case idle
    case working
    case stale
    case unavailable
}

struct CodexActivitySummary: Equatable {
    let state: CodexActivitySummaryState
    let activeTaskCount: Int
    let oldestStartedAt: Date?
    let elapsedSeconds: TimeInterval?
    let lastActivityAt: Date?
    let phase: CodexSafeActivityPhase
    let toolCategory: CodexSafeToolCategory?
    let toolStatus: CodexSafeToolStatus?
    let progressLines: [String]
    let recentEvents: [CodexSafeActivityEvent]
    let tasks: [CodexActivityTask]
}

struct CodexActivityTask: Equatable {
    let state: CodexActivitySummaryState
    let title: String?
    let projectName: String?
    let gitBranch: String?
    let source: String?
    let model: String?
    let modelProvider: String?
    let reasoningEffort: String?
    let sandboxPolicy: String?
    let approvalMode: String?
    let tokensUsed: Int64?
    let activeSubtaskCount: Int
    let subtaskNames: [String]
    let createdAt: Date?
    let startedAt: Date?
    let elapsedSeconds: TimeInterval?
    let lastActivityAt: Date?
    let cliVersion: String?
    let phase: CodexSafeActivityPhase
    let toolCategory: CodexSafeToolCategory?
    let toolStatus: CodexSafeToolStatus?
    let progressLines: [String]
    let recentEvents: [CodexSafeActivityEvent]
}

@MainActor
@Observable
final class CodexSleepProtectionCoordinator {
    static let enabledKey = "codexSleepProtectionEnabled"
    static let keepDisplayAwakeKey = "codexSleepProtectionKeepDisplayAwake"
    static let preventScreenSaverKey = "codexSleepProtectionPreventScreenSaver"
    static let mobileActivityFreshnessWindow: TimeInterval = 10 * 60
    static let mobileActivityRecentEventLimit = 5
    static let mobileActivityTaskCountLimit = 99

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            applyCurrentState()
        }
    }

    var keepDisplayAwake: Bool {
        didSet {
            defaults.set(keepDisplayAwake, forKey: Self.keepDisplayAwakeKey)
            applyCurrentState()
        }
    }

    var preventScreenSaver: Bool {
        didSet {
            defaults.set(preventScreenSaver, forKey: Self.preventScreenSaverKey)
            applyCurrentState()
        }
    }

    private(set) var activeTurnCount = 0
    private(set) var activeTaskCounts: [UsageProvider: Int] = [:]
    private(set) var protectedProviders: Set<UsageProvider> = [.codex]
    private(set) var protectionStatus: CodexSleepProtectionStatus = .idle
    private(set) var hookInstallationStatus: CodexHookInstallationStatus = .notChecked
    private(set) var lastEventAt: Date?
    let closedLidModeManager: ClosedLidModeManager

    private let defaults: UserDefaults
    private let logger = Logger(
        subsystem: "com.techfanseric.aiquotabar",
        category: "CodexActivity"
    )
    private let assertionController: PowerAssertionControlling
    private let hookInstaller: CodexHookInstaller
    private let localActivityProvider: (
        any CodexLocalActivityProviding
    )?
    private let kimiActivityProvider: (
        any KimiLocalActivityProviding
    )?
    private let workspaceNotificationCenter: NotificationCenter
    private var activityTracker = CodexActivityTracker()
    private var localActivitySnapshot = CodexLocalActivitySnapshot.empty
    private var kimiActivitySnapshot = KimiLocalActivitySnapshot.empty
    private var workspaceObserverTokens: [NSObjectProtocol] = []
    private var isSessionActive = true
    private var hasStarted = false

    var keepDisplayAwakeEffective: Bool {
        guard case .active = protectionStatus else { return false }
        return hasStarted
            && isEnabled
            && activeTurnCount > 0
            && keepDisplayAwake
            && isSessionActive
    }

    var preventScreenSaverEffective: Bool {
        keepDisplayAwakeEffective && preventScreenSaver
    }

    @ObservationIgnored private var hookListener: CodexHookListener?
    @ObservationIgnored private var localActivityTask: Task<Void, Never>?
    @ObservationIgnored private var kimiActivityTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        assertionController: PowerAssertionControlling = PowerAssertionController(),
        hookInstaller: CodexHookInstaller = CodexHookInstaller(),
        localActivityProvider: (
            any CodexLocalActivityProviding
        )? = CodexLocalActivityDetector(),
        kimiActivityProvider: (
            any KimiLocalActivityProviding
        )? = KimiLocalActivityDetector(),
        closedLidModeManager: ClosedLidModeManager? = nil,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.defaults = defaults
        self.assertionController = assertionController
        self.hookInstaller = hookInstaller
        self.localActivityProvider = localActivityProvider
        self.kimiActivityProvider = kimiActivityProvider
        self.closedLidModeManager = closedLidModeManager ?? ClosedLidModeManager(
            defaults: defaults
        )
        self.workspaceNotificationCenter = workspaceNotificationCenter
        isEnabled = Self.bool(
            defaults: defaults,
            key: Self.enabledKey,
            defaultValue: true
        )
        keepDisplayAwake = Self.bool(
            defaults: defaults,
            key: Self.keepDisplayAwakeKey,
            defaultValue: true
        )
        preventScreenSaver = Self.bool(
            defaults: defaults,
            key: Self.preventScreenSaverKey,
            defaultValue: true
        )
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        configureCodexHookListener()
        if protectedProviders.contains(.codex),
           let detector = localActivityProvider
            as? CodexLocalActivityDetector {
            receiveLocalSnapshot(
                detector.detectSnapshot(now: Date())
            )
        }
        if protectedProviders.contains(.kimi),
           let detector = kimiActivityProvider
            as? KimiLocalActivityDetector {
            receiveKimiSnapshot(detector.detectSnapshot())
        }
        startLocalActivityMonitoring()
        startKimiActivityMonitoring()
        installWorkspaceObservers()
        closedLidModeManager.start()

        if isEnabled, protectedProviders.contains(.codex) {
            hookInstallationStatus = hookInstaller.install()
        }
        applyCurrentState()
    }

    func stop() {
        guard hasStarted else {
            assertionController.release()
            return
        }

        hasStarted = false
        localActivityTask?.cancel()
        localActivityTask = nil
        kimiActivityTask?.cancel()
        kimiActivityTask = nil
        hookListener?.stop()
        hookListener = nil
        for token in workspaceObserverTokens {
            workspaceNotificationCenter.removeObserver(token)
        }
        workspaceObserverTokens.removeAll()
        activityTracker.reset()
        localActivitySnapshot = .empty
        kimiActivitySnapshot = .empty
        activeTurnCount = 0
        activeTaskCounts = [:]
        lastEventAt = nil
        assertionController.release()
        closedLidModeManager.stop()
        protectionStatus = .idle
    }

    func retryHookInstallation() {
        guard isEnabled, protectedProviders.contains(.codex) else { return }
        hookInstallationStatus = hookInstaller.install()
    }

    func setProtectedProviders(_ providers: Set<UsageProvider>) {
        let supported = providers.intersection([.codex, .kimi])
        guard supported != protectedProviders else { return }
        protectedProviders = supported
        if hasStarted {
            configureCodexHookListener()
            if isEnabled, supported.contains(.codex),
               hookInstallationStatus == .notChecked {
                hookInstallationStatus = hookInstaller.install()
            }
        }
        refreshMergedActivity()
    }

    func activeTaskCount(for provider: UsageProvider) -> Int {
        activeTaskCounts[provider] ?? 0
    }

    var activeProviders: Set<UsageProvider> {
        Set(activeTaskCounts.compactMap { provider, count in
            count > 0 ? provider : nil
        })
    }

    func receive(_ event: CodexHookEvent) {
        guard hasStarted, isEnabled,
              protectedProviders.contains(.codex) else { return }
        activityTracker.receive(event)
        logger.notice(
            "Received Codex hook event \(event.name.rawValue, privacy: .public)"
        )
        refreshMergedActivity()
    }

    func receiveLocalSnapshot(_ snapshot: CodexLocalActivitySnapshot) {
        guard hasStarted else { return }
        localActivitySnapshot = snapshot
        logger.notice(
            "Local Codex detector found \(snapshot.activeSessionIDs.count) active tasks"
        )
        refreshMergedActivity()
    }

    func receiveKimiSnapshot(_ snapshot: KimiLocalActivitySnapshot) {
        guard hasStarted else { return }
        kimiActivitySnapshot = snapshot
        logger.notice(
            "Local Kimi detector found \(snapshot.activeSessionIDs.count) active tasks"
        )
        refreshMergedActivity()
    }

    /// A content-free activity view suitable for a read-only LAN client.
    /// Session, turn, and agent identifiers are used only inside the activity
    /// trackers and are discarded before this value is constructed.
    func mobileActivitySummary(now: Date = Date()) -> CodexActivitySummary {
        let activeSessionIDs = mergedActiveSessionIDs
        let boundedCount = min(
            Self.mobileActivityTaskCountLimit,
            max(0, activeSessionIDs.count)
        )
        let recentEvents = mergedRecentEvents(now: now)
        let tasks = mergedActivityTasks(
            activeSessionIDs: activeSessionIDs,
            now: now)

        guard !activeSessionIDs.isEmpty else {
            return CodexActivitySummary(
                state: hasReliableActivitySource ? .idle : .unavailable,
                activeTaskCount: 0,
                oldestStartedAt: nil,
                elapsedSeconds: nil,
                lastActivityAt: lastEventAt,
                phase: .unknown,
                toolCategory: nil,
                toolStatus: nil,
                progressLines: [],
                recentEvents: recentEvents,
                tasks: [])
        }

        let isFresh = lastEventAt.map {
            now.timeIntervalSince($0)
                <= Self.mobileActivityFreshnessWindow
        } ?? false
        guard isFresh else {
            return CodexActivitySummary(
                state: .stale,
                activeTaskCount: boundedCount,
                oldestStartedAt: nil,
                elapsedSeconds: nil,
                lastActivityAt: lastEventAt,
                phase: .unknown,
                toolCategory: nil,
                toolStatus: nil,
                progressLines: [],
                recentEvents: recentEvents,
                tasks: tasks)
        }

        let oldestStartedAt = reliableMergedOldestStartedAt(
            for: activeSessionIDs)
        let semantic = latestMergedSemantic(
            activeSessionIDs: activeSessionIDs,
            now: now)
        return CodexActivitySummary(
            state: .working,
            activeTaskCount: boundedCount,
            oldestStartedAt: oldestStartedAt,
            elapsedSeconds: oldestStartedAt.map {
                max(0, now.timeIntervalSince($0))
            },
            lastActivityAt: lastEventAt,
            phase: semantic?.phase ?? .unknown,
            toolCategory: semantic?.toolCategory,
            toolStatus: semantic?.toolStatus,
            progressLines: mergedProgressLines(
                activeSessionIDs: activeSessionIDs,
                now: now),
            recentEvents: recentEvents,
            tasks: tasks)
    }

    private func mergedActivityTasks(
        activeSessionIDs: Set<String>,
        now: Date
    ) -> [CodexActivityTask] {
        let cutoff = now.addingTimeInterval(
            -Self.mobileActivityFreshnessWindow)
        return activeSessionIDs.map { sessionID in
            if sessionID.hasPrefix("kimi:") {
                let lastActivityAt = kimiActivitySnapshot.lastEventAt
                let isFresh = lastActivityAt.map {
                    $0 >= cutoff && $0 <= now
                } ?? false
                return CodexActivityTask(
                    state: isFresh ? .working : .stale,
                    title: nil,
                    projectName: nil,
                    gitBranch: nil,
                    source: "Kimi Code",
                    model: nil,
                    modelProvider: "Kimi",
                    reasoningEffort: nil,
                    sandboxPolicy: nil,
                    approvalMode: nil,
                    tokensUsed: nil,
                    activeSubtaskCount: 0,
                    subtaskNames: [],
                    createdAt: nil,
                    startedAt: nil,
                    elapsedSeconds: nil,
                    lastActivityAt: lastActivityAt,
                    cliVersion: nil,
                    phase: .unknown,
                    toolCategory: nil,
                    toolStatus: nil,
                    progressLines: [],
                    recentEvents: [])
            }
            let local = localActivitySnapshot.sessionActivities[sessionID]
            let hookStart = activityTracker.reliableOldestStartedAt(
                for: [sessionID])
            let startedAt = local?.startedAt ?? hookStart
            let lastActivityAt = [
                local?.lastEventAt,
                activityTracker.lastEventAt(for: sessionID),
            ]
            .compactMap { $0 }
            .max()
            let isFresh = lastActivityAt.map {
                $0 >= cutoff && $0 <= now
            } ?? false
            var semanticCandidates = [CodexSafeActivitySemantic]()
            if let semantic = local?.semantic {
                semanticCandidates.append(semantic)
            }
            if let semantic = activityTracker.latestSemantic(for: [sessionID]) {
                semanticCandidates.append(semantic)
            }
            let semantic = semanticCandidates
                .filter { isFresh && $0.at >= cutoff && $0.at <= now }
                .max { $0.at < $1.at }
            let progressLines = Array((local?.progressLines ?? [])
                .filter { isFresh && $0.at >= cutoff && $0.at <= now }
                .sorted { $0.at > $1.at }
                .prefix(2)
                .map(\.text)
                .reversed())
            let taskEvents = Array((local?.recentEvents ?? [])
                .filter { $0.at >= cutoff && $0.at <= now }
                .sorted { $0.at < $1.at }
                .suffix(Self.mobileActivityRecentEventLimit))
            return CodexActivityTask(
                state: isFresh ? .working : .stale,
                title: local?.title,
                projectName: local?.projectName,
                gitBranch: local?.gitBranch,
                source: local?.source,
                model: local?.model,
                modelProvider: local?.modelProvider,
                reasoningEffort: local?.reasoningEffort,
                sandboxPolicy: local?.sandboxPolicy,
                approvalMode: local?.approvalMode,
                tokensUsed: local?.tokensUsed,
                activeSubtaskCount: max(
                    local?.activeSubtaskCount ?? 0,
                    activityTracker.activeSubagentCount(for: sessionID)),
                subtaskNames: local?.subtaskNames ?? [],
                createdAt: local?.createdAt,
                startedAt: startedAt,
                elapsedSeconds: isFresh ? startedAt.map {
                    max(0, now.timeIntervalSince($0))
                } : nil,
                lastActivityAt: lastActivityAt,
                cliVersion: local?.cliVersion,
                phase: semantic?.phase ?? .unknown,
                toolCategory: semantic?.toolCategory,
                toolStatus: semantic?.toolStatus,
                progressLines: progressLines,
                recentEvents: taskEvents)
        }
        .sorted {
            let left = $0.startedAt ?? $0.lastActivityAt ?? .distantFuture
            let right = $1.startedAt ?? $1.lastActivityAt ?? .distantFuture
            if left != right { return left < right }
            return ($0.title ?? "") < ($1.title ?? "")
        }
    }

    private func reliableMergedOldestStartedAt(
        for activeSessionIDs: Set<String>
    ) -> Date? {
        var starts: [Date] = []
        for sessionID in activeSessionIDs {
            guard !sessionID.hasPrefix("kimi:") else { return nil }
            if let localStart = localActivitySnapshot
                .sessionActivities[sessionID]?.startedAt {
                starts.append(localStart)
                continue
            }
            guard let hookStart = activityTracker
                .reliableOldestStartedAt(for: [sessionID]) else {
                return nil
            }
            starts.append(hookStart)
        }
        return starts.min()
    }

    private func latestMergedSemantic(
        activeSessionIDs: Set<String>,
        now: Date
    ) -> CodexSafeActivitySemantic? {
        let cutoff = now.addingTimeInterval(
            -Self.mobileActivityFreshnessWindow)
        var candidates = activeSessionIDs.compactMap {
            localActivitySnapshot.sessionActivities[$0]?.semantic
        }
        if let hookSemantic = activityTracker.latestSemantic(
            for: activeSessionIDs) {
            candidates.append(hookSemantic)
        }
        return candidates
            .filter { $0.at >= cutoff && $0.at <= now }
            .max { $0.at < $1.at }
    }

    private func mergedProgressLines(
        activeSessionIDs: Set<String>,
        now: Date
    ) -> [String] {
        let cutoff = now.addingTimeInterval(
            -Self.mobileActivityFreshnessWindow)
        var seen = Set<String>()
        return Array(activeSessionIDs
            .flatMap {
                localActivitySnapshot.sessionActivities[$0]?
                    .progressLines ?? []
            }
            .filter { $0.at >= cutoff && $0.at <= now }
            .sorted { $0.at > $1.at }
            .filter { seen.insert($0.text).inserted }
            .prefix(2)
            .map(\.text)
            .reversed())
    }

    private func mergedRecentEvents(
        now: Date
    ) -> [CodexSafeActivityEvent] {
        var events = activityTracker.recentEvents(
            now: now,
            maximumAge: Self.mobileActivityFreshnessWindow,
            maximumCount: 32)
        events.append(contentsOf: localActivitySnapshot.sessionActivities
            .values.flatMap(\.recentEvents))
        let cutoff = now.addingTimeInterval(
            -Self.mobileActivityFreshnessWindow)
        var seen = Set<String>()
        let unique = events
            .filter { $0.at >= cutoff && $0.at <= now }
            .sorted { $0.at < $1.at }
            .filter {
                let key = "\($0.kind.rawValue):\($0.at.timeIntervalSince1970)"
                return seen.insert(key).inserted
            }
        return Array(unique.suffix(Self.mobileActivityRecentEventLimit))
    }

    private func refreshMergedActivity() {
        let codexCount = protectedProviders.contains(.codex)
            ? mergedCodexActiveSessionIDs.count
            : 0
        let kimiCount = protectedProviders.contains(.kimi)
            ? kimiActivitySnapshot.activeSessionIDs.count
            : 0
        activeTaskCounts = [
            .codex: codexCount,
            .kimi: kimiCount,
        ]
        activeTurnCount = codexCount + kimiCount
        lastEventAt = [
            protectedProviders.contains(.codex)
                ? activityTracker.lastEventAt
                : nil,
            protectedProviders.contains(.codex)
                ? localActivitySnapshot.lastEventAt
                : nil,
            protectedProviders.contains(.kimi)
                ? kimiActivitySnapshot.lastEventAt
                : nil,
        ]
        .compactMap { $0 }
        .max()
        applyCurrentState()
    }

    private var mergedActiveSessionIDs: Set<String> {
        var result = protectedProviders.contains(.codex)
            ? mergedCodexActiveSessionIDs
            : []
        if protectedProviders.contains(.kimi) {
            result.formUnion(kimiActivitySnapshot.activeSessionIDs)
        }
        return result
    }

    private var mergedCodexActiveSessionIDs: Set<String> {
        activityTracker.activeSessionIDs
            .union(localActivitySnapshot.activeSessionIDs)
    }

    private var hasReliableActivitySource: Bool {
        guard hasStarted else { return false }
        let hasCodexSource = protectedProviders.contains(.codex)
            && (localActivityProvider != nil
                || hookInstallationStatus == .installed
                || activityTracker.lastEventAt != nil)
        let hasKimiSource = protectedProviders.contains(.kimi)
            && kimiActivityProvider != nil
        return hasCodexSource || hasKimiSource
    }

    private func applyCurrentState() {
        let isWorking = activeTurnCount > 0
        closedLidModeManager.setTaskActive(
            hasStarted && isEnabled && isWorking
        )
        guard hasStarted, isEnabled, isWorking else {
            assertionController.release()
            protectionStatus = .idle
            return
        }

        do {
            let shouldProtectDisplay = keepDisplayAwake && isSessionActive
            try assertionController.acquire(
                keepDisplayAwake: shouldProtectDisplay,
                declareUserActivity: shouldProtectDisplay && preventScreenSaver
            )
            protectionStatus = .active
        } catch {
            logger.error(
                "Could not acquire Codex power assertions: \(error.localizedDescription, privacy: .public)"
            )
            assertionController.release()
            protectionStatus = .failed(error.localizedDescription)
        }
    }

    private func startLocalActivityMonitoring() {
        guard let localActivityProvider else { return }
        localActivityTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let shouldRead = self.protectedProviders.contains(.codex)
                let snapshot = shouldRead
                    ? await localActivityProvider.snapshot()
                    : .empty
                guard !Task.isCancelled else { return }
                self.receiveLocalSnapshot(snapshot)
                do {
                    try await Task.sleep(
                        nanoseconds: 2_000_000_000
                    )
                } catch {
                    return
                }
            }
        }
    }

    private func startKimiActivityMonitoring() {
        guard let kimiActivityProvider else { return }
        kimiActivityTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let shouldRead = self.protectedProviders.contains(.kimi)
                let snapshot = shouldRead
                    ? await kimiActivityProvider.snapshot()
                    : .empty
                guard !Task.isCancelled else { return }
                self.receiveKimiSnapshot(snapshot)
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func configureCodexHookListener() {
        let shouldListen = protectedProviders.contains(.codex)
        if shouldListen, hookListener == nil {
            let listener = CodexHookListener { [weak self] event in
                self?.receive(event)
            }
            hookListener = listener
            listener.start()
        } else if !shouldListen {
            hookListener?.stop()
            hookListener = nil
            activityTracker.reset()
            localActivitySnapshot = .empty
        }
    }

    private func installWorkspaceObservers() {
        let resignToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isSessionActive = false
                self?.applyCurrentState()
            }
        }
        workspaceObserverTokens.append(resignToken)

        let becomeToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isSessionActive = true
                self?.applyCurrentState()
            }
        }
        workspaceObserverTokens.append(becomeToken)
    }

    private static func bool(
        defaults: UserDefaults,
        key: String,
        defaultValue: Bool
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    deinit {
        assertionController.release()
    }
}
