import AIQuotaBarSleepShared
import Foundation
import IOKit.ps

enum ClosedLidModeStatus: Equatable {
    case disabled
    case requiresInstallation
    case installing
    case checking
    case ready
    case active
    case suspendedLowBattery(Int)
    case suspendedThermal
    case suspendedMaximumDuration
    case unavailable(String)
}

enum ClosedLidSafetyDecision: Equatable {
    case allowed
    case lowBattery(Int)
    case thermalPressure
}

struct ClosedLidSafetyPolicy {
    static let minimumBatteryPercentage = 20

    static func evaluate(
        batteryPercentage: Int?,
        hasInternalBattery: Bool,
        isOnACPower: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> ClosedLidSafetyDecision {
        if thermalState == .serious || thermalState == .critical {
            return .thermalPressure
        }
        if !isOnACPower && hasInternalBattery {
            let percentage = batteryPercentage ?? 0
            if percentage < minimumBatteryPercentage {
                return .lowBattery(percentage)
            }
        }
        return .allowed
    }

    static func hasReachedMaximumDuration(
        startedAt: Date?,
        now: Date,
        maximumDuration: TimeInterval
    ) -> Bool {
        guard let startedAt else { return false }
        return now.timeIntervalSince(startedAt) >= maximumDuration
    }
}

private struct PowerEnvironmentSnapshot {
    let batteryPercentage: Int?
    let hasInternalBattery: Bool
    let isOnACPower: Bool
    let thermalState: ProcessInfo.ThermalState

    var safetyDecision: ClosedLidSafetyDecision {
        ClosedLidSafetyPolicy.evaluate(
            batteryPercentage: batteryPercentage,
            hasInternalBattery: hasInternalBattery,
            isOnACPower: isOnACPower,
            thermalState: thermalState
        )
    }
}

@MainActor
@Observable
final class ClosedLidModeManager {
    static let enabledKey = "codexSleepProtectionAllowClosedLid"
    static let maximumLeaseDuration: TimeInterval = 12 * 60 * 60
    private static let heartbeatInterval: TimeInterval = 30
    private static let heartbeatTimeout: TimeInterval = 90

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            reconcile(allowInstallation: isEnabled)
        }
    }

    private(set) var status: ClosedLidModeStatus = .disabled

    private let defaults: UserDefaults
    private let helperInstaller: PrivilegedSleepHelperInstaller
    private let leaseID = UUID().uuidString
    private var connection: NSXPCConnection?
    private var heartbeatTimer: Timer?
    private var isTaskActive = false
    private var hasLease = false
    private var leaseStartedAt: Date?
    private var maximumDurationReachedForCurrentTask = false
    private var hasStarted = false
    private var isInstalling = false
    private var isCheckingHelper = false
    private var hasVerifiedHelper = false

    init(
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main,
        helperInstaller: PrivilegedSleepHelperInstaller? = nil
    ) {
        self.defaults = defaults
        self.helperInstaller = helperInstaller
            ?? PrivilegedSleepHelperInstaller(bundle: bundle)
        if defaults.object(forKey: Self.enabledKey) == nil {
            isEnabled = false
        } else {
            isEnabled = defaults.bool(forKey: Self.enabledKey)
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: Self.heartbeatInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.heartbeatAndReconcile()
            }
        }
        heartbeatTimer?.tolerance = 3
        reconcile(allowInstallation: false)
    }

    func stop() {
        hasStarted = false
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        releaseLease()
        invalidateConnection()
        status = .disabled
    }

    func setTaskActive(_ active: Bool) {
        guard isTaskActive != active else { return }
        isTaskActive = active
        if !active {
            maximumDurationReachedForCurrentTask = false
        }
        reconcile(allowInstallation: false)
    }

    func retryRegistration() {
        guard isEnabled else { return }
        hasVerifiedHelper = false
        invalidateConnection()
        reconcile(allowInstallation: true)
    }

    private func heartbeatAndReconcile() {
        guard hasStarted else { return }
        let environment = currentPowerEnvironment()

        if hasLease {
            if ClosedLidSafetyPolicy.hasReachedMaximumDuration(
                startedAt: leaseStartedAt,
                now: Date(),
                maximumDuration: Self.maximumLeaseDuration
            ) {
                maximumDurationReachedForCurrentTask = true
                releaseLease()
                status = .suspendedMaximumDuration
                return
            }
            switch environment.safetyDecision {
            case .allowed:
                break
            case let .lowBattery(percentage):
                releaseLease()
                status = .suspendedLowBattery(percentage)
                return
            case .thermalPressure:
                releaseLease()
                status = .suspendedThermal
                return
            }
            heartbeat()
        }

        reconcile(allowInstallation: false)
    }

    private func reconcile(allowInstallation: Bool) {
        guard hasStarted else { return }
        guard isEnabled else {
            releaseLease()
            status = .disabled
            return
        }

        guard isBundledHelperAvailable else {
            releaseLease()
            status = .unavailable(
                "The privileged helper is only available in the packaged app."
            )
            return
        }

        switch helperInstaller.installationStatus() {
        case .missing, .outdated:
            releaseLease()
            hasVerifiedHelper = false
            if allowInstallation {
                installHelper()
            } else if !isInstalling {
                status = .requiresInstallation
            }

        case .installed:
            guard !isInstalling else { return }
            guard hasVerifiedHelper else {
                checkHelper()
                return
            }
            if isTaskActive {
                acquireLeaseIfSafe()
            } else {
                releaseLease()
                status = .ready
            }
        }
    }

    private func installHelper() {
        guard !isInstalling else { return }
        isInstalling = true
        isCheckingHelper = false
        hasVerifiedHelper = false
        status = .installing
        invalidateConnection()
        let installer = helperInstaller

        Task { [weak self] in
            do {
                try await Task.detached(
                    priority: .userInitiated
                ) {
                    try installer.install()
                }.value
                guard let self else { return }
                self.isInstalling = false
                self.reconcile(allowInstallation: false)
            } catch {
                guard let self else { return }
                self.isInstalling = false
                self.status = .unavailable(
                    error.localizedDescription)
            }
        }
    }

    private func checkHelper() {
        guard !isCheckingHelper else { return }
        isCheckingHelper = true
        status = .checking

        guard let proxy = helperProxy() else {
            isCheckingHelper = false
            status = .unavailable(
                "Could not connect to the installed helper.")
            return
        }
        proxy.healthCheck { [weak self] succeeded, message in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isCheckingHelper = false
                self.hasVerifiedHelper = succeeded
                if succeeded {
                    self.reconcile(allowInstallation: false)
                } else {
                    self.status = .unavailable(message)
                }
            }
        }
    }

    private func acquireLeaseIfSafe() {
        guard !maximumDurationReachedForCurrentTask else {
            releaseLease()
            status = .suspendedMaximumDuration
            return
        }
        let environment = currentPowerEnvironment()
        switch environment.safetyDecision {
        case .allowed:
            break
        case let .lowBattery(percentage):
            releaseLease()
            status = .suspendedLowBattery(percentage)
            return
        case .thermalPressure:
            releaseLease()
            status = .suspendedThermal
            return
        }
        guard !hasLease else {
            status = .active
            return
        }

        let proxy = helperProxy()
        proxy?.acquireClosedLidLease(
            leaseID,
            heartbeatTimeout: Self.heartbeatTimeout
        ) { [weak self] succeeded, message in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hasLease = succeeded
                if succeeded {
                    self.leaseStartedAt = Date()
                    self.status = .active
                } else {
                    self.leaseStartedAt = nil
                    self.status = .unavailable(
                        message ?? "The privileged helper rejected the lease."
                    )
                }
            }
        }
    }

    private func heartbeat() {
        helperProxy()?.heartbeatClosedLidLease(leaseID) { [weak self] valid in
            Task { @MainActor [weak self] in
                guard let self, !valid else { return }
                self.hasLease = false
                self.leaseStartedAt = nil
                self.invalidateConnection()
                self.reconcile(allowInstallation: false)
            }
        }
    }

    private func releaseLease() {
        guard hasLease else {
            leaseStartedAt = nil
            return
        }

        hasLease = false
        leaseStartedAt = nil
        helperProxy()?.releaseClosedLidLease(leaseID) { [weak self] succeeded, message in
            Task { @MainActor [weak self] in
                guard let self, !succeeded else { return }
                self.status = .unavailable(
                    message ?? "The privileged helper could not restore sleep."
                )
            }
        }
    }

    private func helperProxy() -> AIQuotaBarSleepHelperProtocol? {
        if connection == nil {
            let newConnection = NSXPCConnection(
                machServiceName: SleepHelperConstants.machServiceName,
                options: .privileged
            )
            newConnection.remoteObjectInterface = NSXPCInterface(
                with: AIQuotaBarSleepHelperProtocol.self
            )
            newConnection.invalidationHandler = {
                [weak self, weak newConnection] in
                Task {
                    @MainActor [weak self, weak newConnection] in
                    guard let self,
                          let newConnection,
                          self.connection === newConnection else {
                        return
                    }
                    self.connection = nil
                    self.hasLease = false
                    self.leaseStartedAt = nil
                    self.hasVerifiedHelper = false
                    self.isCheckingHelper = false
                }
            }
            newConnection.interruptionHandler = newConnection.invalidationHandler
            newConnection.resume()
            connection = newConnection
        }

        guard let activeConnection = connection else {
            return nil
        }
        return activeConnection.remoteObjectProxyWithErrorHandler {
            [weak self, weak activeConnection] error in
            Task {
                @MainActor [weak self, weak activeConnection] in
                guard let self,
                      let activeConnection,
                      self.connection === activeConnection else {
                    return
                }
                self.status = .unavailable(
                    error.localizedDescription)
                self.hasLease = false
                self.leaseStartedAt = nil
                self.hasVerifiedHelper = false
                self.isCheckingHelper = false
            }
        } as? AIQuotaBarSleepHelperProtocol
    }

    private func invalidateConnection() {
        connection?.invalidate()
        connection = nil
    }

    private var isBundledHelperAvailable: Bool {
        helperInstaller.hasBundledPayload
    }

    private func currentPowerEnvironment() -> PowerEnvironmentSnapshot {
        var batteryPercentage: Int?
        var hasInternalBattery = false
        var isOnACPower = false

        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let description = IOPSGetPowerSourceDescription(
                    blob,
                    source
                )?.takeUnretainedValue() as? [String: Any] else {
                    continue
                }

                if description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue {
                    isOnACPower = true
                }
                guard description[kIOPSTypeKey] as? String
                    == kIOPSInternalBatteryType else {
                    continue
                }
                hasInternalBattery = true
                if let current = description[kIOPSCurrentCapacityKey] as? Int,
                   let maximum = description[kIOPSMaxCapacityKey] as? Int,
                   maximum > 0 {
                    batteryPercentage = Int(
                        (Double(current) / Double(maximum) * 100).rounded()
                    )
                }
            }
        }

        return PowerEnvironmentSnapshot(
            batteryPercentage: batteryPercentage,
            hasInternalBattery: hasInternalBattery,
            isOnACPower: isOnACPower,
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }
}
