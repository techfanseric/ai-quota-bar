import AppKit
import Foundation
import OSLog

enum CodexSleepProtectionStatus: Equatable {
    case idle
    case active
    case failed(String)
}

@MainActor
@Observable
final class CodexSleepProtectionCoordinator {
    static let enabledKey = "codexSleepProtectionEnabled"
    static let keepDisplayAwakeKey = "codexSleepProtectionKeepDisplayAwake"
    static let preventScreenSaverKey = "codexSleepProtectionPreventScreenSaver"

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
    private let workspaceNotificationCenter: NotificationCenter
    private var activityTracker = CodexActivityTracker()
    private var localActivitySnapshot = CodexLocalActivitySnapshot.empty
    private var workspaceObserverTokens: [NSObjectProtocol] = []
    private var isSessionActive = true
    private var hasStarted = false

    @ObservationIgnored private var hookListener: CodexHookListener?
    @ObservationIgnored private var localActivityTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        assertionController: PowerAssertionControlling = PowerAssertionController(),
        hookInstaller: CodexHookInstaller = CodexHookInstaller(),
        localActivityProvider: (
            any CodexLocalActivityProviding
        )? = CodexLocalActivityDetector(),
        closedLidModeManager: ClosedLidModeManager? = nil,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.defaults = defaults
        self.assertionController = assertionController
        self.hookInstaller = hookInstaller
        self.localActivityProvider = localActivityProvider
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
        let listener = CodexHookListener { [weak self] event in
            self?.receive(event)
        }
        hookListener = listener
        listener.start()
        if let detector = localActivityProvider
            as? CodexLocalActivityDetector {
            receiveLocalSnapshot(
                detector.detectSnapshot(now: Date())
            )
        }
        startLocalActivityMonitoring()
        installWorkspaceObservers()
        closedLidModeManager.start()

        if isEnabled {
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
        hookListener?.stop()
        hookListener = nil
        for token in workspaceObserverTokens {
            workspaceNotificationCenter.removeObserver(token)
        }
        workspaceObserverTokens.removeAll()
        activityTracker.reset()
        localActivitySnapshot = .empty
        activeTurnCount = 0
        lastEventAt = nil
        assertionController.release()
        closedLidModeManager.stop()
        protectionStatus = .idle
    }

    func retryHookInstallation() {
        guard isEnabled else { return }
        hookInstallationStatus = hookInstaller.install()
    }

    func receive(_ event: CodexHookEvent) {
        guard hasStarted, isEnabled else { return }
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

    private func refreshMergedActivity() {
        let activeSessionIDs = activityTracker.activeSessionIDs
            .union(localActivitySnapshot.activeSessionIDs)
        activeTurnCount = activeSessionIDs.count
        lastEventAt = [
            activityTracker.lastEventAt,
            localActivitySnapshot.lastEventAt
        ]
        .compactMap { $0 }
        .max()
        applyCurrentState()
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
                let snapshot = await localActivityProvider.snapshot()
                guard !Task.isCancelled else { return }
                self?.receiveLocalSnapshot(snapshot)
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
