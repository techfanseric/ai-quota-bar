import AIQuotaBarSleepShared
import CryptoKit
import Foundation
import IOKit.ps
import OSLog
import Security

private let logger = Logger(
    subsystem: "com.techfanseric.aiquotabar.sleep-helper",
    category: "ClosedLidLease"
)

private struct RestoreMarker: Codable {
    let previousState: PMSetSleepState
    let createdAt: Date
}

private struct Lease {
    let ownerID: UUID
    let heartbeatTimeout: TimeInterval
    var expiresAt: Date
}

private enum SleepHelperError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(message):
            return message
        }
    }
}

private final class ClosedLidLeaseService {
    static let shared = ClosedLidLeaseService()

    private let queue = DispatchQueue(
        label: "com.techfanseric.aiquotabar.sleep-helper.state"
    )
    private let markerURL = URL(
        fileURLWithPath: "/var/db/com.techfanseric.aiquotabar.closed-lid-restore.json"
    )
    private var leases: [String: Lease] = [:]
    private var expiryTimer: DispatchSourceTimer?
    private var powerSourceNotification: CFRunLoopSource?
    private var lastPowerSourceReconcileAt = Date.distantPast

    private init() {
        queue.sync {
            restoreInterruptedChangeIfNeeded()
            startExpiryTimer()
        }
        startPowerSourceMonitoring()
    }

    func acquire(
        leaseID: String,
        ownerID: UUID,
        heartbeatTimeout: TimeInterval,
        reply: @escaping (Bool, String?) -> Void
    ) {
        queue.async {
            do {
                if self.leases.isEmpty {
                    try self.enableClosedLidMode()
                    logger.notice("Closed-lid mode enabled (disablesleep=1)")
                }
                let timeout = min(120, max(45, heartbeatTimeout))
                self.leases[leaseID] = Lease(
                    ownerID: ownerID,
                    heartbeatTimeout: timeout,
                    expiresAt: Date().addingTimeInterval(timeout)
                )
                logger.notice(
                    "Lease acquired (\(leaseID, privacy: .public), timeout \(timeout, privacy: .public)s)"
                )
                reply(true, nil)
            } catch {
                logger.error(
                    "Lease acquire failed: \(error.localizedDescription, privacy: .public)"
                )
                reply(false, error.localizedDescription)
            }
        }
    }

    func heartbeat(
        leaseID: String,
        ownerID: UUID,
        reply: @escaping (Bool) -> Void
    ) {
        queue.async {
            guard var lease = self.leases[leaseID],
                  lease.ownerID == ownerID else {
                logger.warning(
                    "Heartbeat rejected for unknown lease \(leaseID, privacy: .public)"
                )
                reply(false)
                return
            }
            lease.expiresAt = Date().addingTimeInterval(lease.heartbeatTimeout)
            self.leases[leaseID] = lease
            reply(true)
        }
    }

    func release(
        leaseID: String,
        ownerID: UUID,
        reply: @escaping (Bool, String?) -> Void
    ) {
        queue.async {
            if self.leases[leaseID]?.ownerID == ownerID {
                self.leases.removeValue(forKey: leaseID)
                logger.notice(
                    "Lease released (\(leaseID, privacy: .public))"
                )
            }
            do {
                if self.leases.isEmpty {
                    try self.restoreOriginalState()
                }
                reply(true, nil)
            } catch {
                logger.error(
                    "Lease release failed to restore sleep: \(error.localizedDescription, privacy: .public)"
                )
                reply(false, error.localizedDescription)
            }
        }
    }

    private func startExpiryTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // 5s sweep: keeps the external-override window (another tool writing
        // disablesleep 0) short while a lease is active.
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date()
            let countBefore = self.leases.count
            self.leases = self.leases.filter { $0.value.expiresAt > now }
            if self.leases.count < countBefore {
                logger.notice(
                    "Lease(s) expired without heartbeat (\(countBefore - self.leases.count, privacy: .public) dropped)"
                )
            }
            if self.leases.isEmpty {
                try? self.restoreOriginalState()
            } else {
                self.reconcileSleepDisabledFlag()
            }
        }
        timer.resume()
        expiryTimer = timer
    }

    /// Read-back verification: while any lease is active, the kernel
    /// SleepDisabled flag must stay set. Power-source transitions on Apple
    /// Silicon and system updates can silently clear it, so re-assert on
    /// drift instead of trusting the one-time write.
    private func reconcileSleepDisabledFlag() {
        guard !leases.isEmpty,
              FileManager.default.fileExists(atPath: markerURL.path) else {
            return
        }
        guard let state = try? readCurrentState() else {
            logger.error("Reconcile could not read pmset state")
            return
        }
        guard !state.isSleepDisabled else { return }
        logger.warning(
            "SleepDisabled was cleared externally while a lease is active; re-asserting (possible conflict with another power-management tool)"
        )
        do {
            try runPMSet(arguments: ["-a", "disablesleep", "1"])
        } catch {
            logger.error(
                "Re-asserting disablesleep failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func handlePowerSourceChange() {
        queue.async {
            // Power-source notifications also fire on battery percentage
            // ticks; throttle the pmset read-back to at most once per 10s.
            let now = Date()
            guard now.timeIntervalSince(self.lastPowerSourceReconcileAt) >= 10
            else { return }
            self.lastPowerSourceReconcileAt = now
            self.reconcileSleepDisabledFlag()
        }
    }

    private func startPowerSourceMonitoring() {
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            Unmanaged<ClosedLidLeaseService>
                .fromOpaque(context)
                .takeUnretainedValue()
                .handlePowerSourceChange()
        }
        guard let source = IOPSNotificationCreateRunLoopSource(
            callback,
            Unmanaged.passUnretained(self).toOpaque()
        )?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
        powerSourceNotification = source
    }

    private func enableClosedLidMode() throws {
        let previousState = try readCurrentState()
        let marker = RestoreMarker(
            previousState: previousState,
            createdAt: Date()
        )
        let data = try JSONEncoder().encode(marker)
        try data.write(to: markerURL, options: .atomic)
        _ = chmod(markerURL.path, S_IRUSR | S_IWUSR)

        do {
            try runPMSet(arguments: ["-a", "disablesleep", "1"])
        } catch {
            try? FileManager.default.removeItem(at: markerURL)
            throw error
        }
    }

    private func restoreInterruptedChangeIfNeeded() {
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return }
        logger.notice(
            "Found leftover restore marker at startup; restoring original sleep state"
        )
        try? restoreOriginalState()
    }

    private func restoreOriginalState() throws {
        guard FileManager.default.fileExists(atPath: markerURL.path) else {
            return
        }
        guard let data = try? Data(contentsOf: markerURL),
              let marker = try? JSONDecoder().decode(RestoreMarker.self, from: data) else {
            try runPMSet(arguments: ["-a", "disablesleep", "0"])
            try FileManager.default.removeItem(at: markerURL)
            return
        }

        for command in PMSetSleepStateCodec.restorationCommands(
            for: marker.previousState
        ) {
            try runPMSet(arguments: command.arguments)
        }

        try FileManager.default.removeItem(at: markerURL)
        logger.notice("Original sleep state restored (disablesleep off)")
    }

    private func readCurrentState() throws -> PMSetSleepState {
        let output = try runPMSet(arguments: ["-g"])
        return PMSetSleepStateCodec.parseCurrentOutput(output)
    }

    @discardableResult
    private func runPMSet(arguments: [String]) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: error, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SleepHelperError.commandFailed(
                message?.isEmpty == false ? message! : "pmset exited with \(process.terminationStatus)"
            )
        }
        return String(data: output, encoding: .utf8) ?? ""
    }
}

private final class SleepHelperClient: NSObject, AIQuotaBarSleepHelperProtocol {
    let ownerID = UUID()
    private let service: ClosedLidLeaseService

    init(service: ClosedLidLeaseService) {
        self.service = service
    }

    func healthCheck(
        withReply reply: @escaping (Bool, String) -> Void
    ) {
        reply(true, "AIQuotaBarSleepHelper is ready.")
    }

    func acquireClosedLidLease(
        _ leaseID: String,
        heartbeatTimeout: TimeInterval,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        service.acquire(
            leaseID: leaseID,
            ownerID: ownerID,
            heartbeatTimeout: heartbeatTimeout,
            reply: reply
        )
    }

    func heartbeatClosedLidLease(
        _ leaseID: String,
        withReply reply: @escaping (Bool) -> Void
    ) {
        service.heartbeat(
            leaseID: leaseID,
            ownerID: ownerID,
            reply: reply
        )
    }

    func releaseClosedLidLease(
        _ leaseID: String,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        service.release(
            leaseID: leaseID,
            ownerID: ownerID,
            reply: reply
        )
    }
}

private final class SleepHelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard Self.hasExpectedCodeIdentity(processID: connection.processIdentifier) else {
            return false
        }

        let client = SleepHelperClient(service: .shared)
        connection.exportedInterface = NSXPCInterface(
            with: AIQuotaBarSleepHelperProtocol.self
        )
        connection.exportedObject = client
        // Deliberately no invalidation/interruption handlers that drop
        // leases: XPC interruptions are transient and the client may
        // reconnect within seconds. Leases expire on their own after one
        // heartbeat timeout, and the expiry timer then restores the
        // original sleep state, so a genuinely dead client still
        // re-enables sleep automatically — without a connection hiccup
        // re-enabling sleep while the lid is closed.
        connection.resume()
        return true
    }

    private static func hasExpectedCodeIdentity(processID: pid_t) -> Bool {
        var guestCode: SecCode?
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: processID)
        ] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            [],
            &guestCode
        ) == errSecSuccess,
              let guestCode,
              SecCodeCheckValidity(
                guestCode,
                [],
                nil) == errSecSuccess,
              let guestInfo = signingInfo(for: guestCode),
              guestInfo[kSecCodeInfoIdentifier as String] as? String
                == SleepHelperConstants.mainAppBundleIdentifier else {
            return false
        }

        guard let guestTeam =
            guestInfo[kSecCodeInfoTeamIdentifier as String] as? String else {
            return hasPinnedAdHocIdentity(guestInfo)
        }

        var selfCode: SecCode?
        guard SecCodeCopySelf(
            [],
            &selfCode
        ) == errSecSuccess,
              let selfCode,
              let selfInfo = signingInfo(for: selfCode),
              let selfTeam = selfInfo[kSecCodeInfoTeamIdentifier as String] as? String else {
            return false
        }
        return guestTeam == selfTeam
    }

    private static func hasPinnedAdHocIdentity(
        _ guestInfo: [String: Any]
    ) -> Bool {
        let markerURL = URL(
            fileURLWithPath:
                SleepHelperConstants.authorizedClientMarkerPath)
        guard let marker = try? String(
            contentsOf: markerURL,
            encoding: .utf8) else {
            return false
        }

        let lines = marker
            .split(
                separator: "\n",
                omittingEmptySubsequences: true)
            .map(String.init)
        guard lines.count == 2,
              let executableURL =
                guestInfo[
                    kSecCodeInfoMainExecutable as String] as? URL else {
            return false
        }

        let expectedPath = URL(
            fileURLWithPath: lines[0])
            .standardizedFileURL.path
        let actualURL = executableURL.standardizedFileURL
        guard actualURL.path == expectedPath,
              let data = try? Data(
                contentsOf: actualURL,
                options: .mappedIfSafe) else {
            return false
        }

        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return digest == lines[1].lowercased()
    }

    private static func signingInfo(for code: SecCode) -> [String: Any]? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess else {
            return nil
        }
        return information as? [String: Any]
    }
}

// Eagerly initialize the lease service on the main thread so its startup
// self-heal, expiry timer, and power-source monitoring are all live even
// before the first client connects (the power-source run-loop source must
// be attached to this main run loop).
_ = ClosedLidLeaseService.shared

private let delegate = SleepHelperListenerDelegate()
private let listener = NSXPCListener(
    machServiceName: SleepHelperConstants.machServiceName
)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
