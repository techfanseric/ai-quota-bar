import AIQuotaBarSleepShared
import Foundation

enum SleepHelperCommandLine {
    private enum Command: String {
        case status = "--sleep-helper-status"
        case register = "--sleep-helper-register"
        case health = "--sleep-helper-health"
        case selfTest = "--sleep-helper-self-test"
    }

    static func runIfRequested(
        arguments: [String] = CommandLine.arguments
    ) -> Int32? {
        guard let rawCommand = arguments.dropFirst().first,
              let command = Command(rawValue: rawCommand) else {
            return nil
        }

        switch command {
        case .status:
            print(
                "sleep-helper installation: "
                    + installationStatusName(
                        installer.installationStatus()))
            return 0

        case .register:
            return registerService()

        case .health:
            return runHealthCheck()

        case .selfTest:
            return runLeaseSelfTest()
        }
    }

    private static let installer =
        PrivilegedSleepHelperInstaller()

    private static func registerService() -> Int32 {
        if installer.installationStatus() == .installed {
            print("sleep-helper installation: installed")
            return 0
        }

        do {
            try installer.install()
            print("sleep-helper installation: installed")
            return 0
        } catch {
            fputs(
                "sleep-helper installation failed: "
                    + "\(error.localizedDescription)\n",
                stderr)
            return 1
        }
    }

    private static func runHealthCheck() -> Int32 {
        guard installer.installationStatus() == .installed else {
            fputs(
                "sleep-helper health failed: helper is "
                    + installationStatusName(
                        installer.installationStatus())
                    + "\n",
                stderr)
            return 1
        }

        let client = SynchronousSleepHelperClient()
        defer { client.invalidate() }
        switch client.healthCheck() {
        case let .success(message):
            print("sleep-helper health: \(message)")
            return 0
        case let .failure(message):
            fputs("sleep-helper health failed: \(message)\n", stderr)
            return 1
        }
    }

    private static func runLeaseSelfTest() -> Int32 {
        guard installer.installationStatus() == .installed else {
            fputs(
                "sleep-helper self-test failed: helper is "
                    + installationStatusName(
                        installer.installationStatus())
                    + "\n",
                stderr)
            return 1
        }

        do {
            let stateBefore = try readSleepState()
            let client = SynchronousSleepHelperClient()
            defer { client.invalidate() }

            let leaseID = "diagnostic-\(UUID().uuidString)"
            let acquisition = client.acquireLease(
                leaseID,
                heartbeatTimeout: 45)
            guard case .success = acquisition else {
                if case let .failure(message) = acquisition {
                    fputs(
                        "sleep-helper self-test failed to acquire lease: "
                            + "\(message)\n",
                        stderr)
                }
                return 1
            }

            let enabledState = try readSleepState()
            let release = client.releaseLease(leaseID)
            guard case .success = release else {
                if case let .failure(message) = release {
                    fputs(
                        "sleep-helper self-test failed to release lease: "
                            + "\(message)\n",
                        stderr)
                }
                return 1
            }

            let restoredState = try readSleepState()
            guard knownValues(in: enabledState).allSatisfy({ $0 }) else {
                fputs(
                    "sleep-helper self-test failed: disablesleep was not "
                        + "enabled for every known power source\n",
                    stderr)
                return 1
            }
            guard restoredState == stateBefore else {
                fputs(
                    "sleep-helper self-test failed: original pmset state "
                        + "was not restored\n",
                    stderr)
                return 1
            }

            print(
                "sleep-helper self-test: lease enabled disablesleep and "
                    + "restored the original state")
            return 0
        } catch {
            fputs(
                "sleep-helper self-test failed: "
                    + "\(error.localizedDescription)\n",
                stderr)
            return 1
        }
    }

    private static func readSleepState() throws -> PMSetSleepState {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = error.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)
                ?? "pmset exited with \(process.terminationStatus)"
            throw SleepHelperDiagnosticError.commandFailed(message)
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return PMSetSleepStateCodec.parseCurrentOutput(text)
    }

    private static func knownValues(
        in state: PMSetSleepState
    ) -> [Bool] {
        if let global = state.global {
            return [global]
        }
        return [state.battery, state.charger, state.ups]
            .compactMap { $0 }
    }

    private static func installationStatusName(
        _ status:
            PrivilegedSleepHelperInstaller.InstallationStatus
    ) -> String {
        switch status {
        case .missing: return "missing"
        case .outdated: return "outdated"
        case .installed: return "installed"
        }
    }
}

private enum SleepHelperDiagnosticResult {
    case success(String)
    case failure(String)
}

private enum SleepHelperDiagnosticError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(message): return message
        }
    }
}

private final class SynchronousSleepHelperClient {
    private let connection: NSXPCConnection

    init() {
        connection = NSXPCConnection(
            machServiceName: SleepHelperConstants.machServiceName,
            options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(
            with: AIQuotaBarSleepHelperProtocol.self)
        connection.resume()
    }

    func invalidate() {
        connection.invalidate()
    }

    func healthCheck() -> SleepHelperDiagnosticResult {
        waitForReply { proxy, finish in
            proxy.healthCheck { succeeded, message in
                finish(
                    succeeded
                        ? .success(message)
                        : .failure(message))
            }
        }
    }

    func acquireLease(
        _ leaseID: String,
        heartbeatTimeout: TimeInterval
    ) -> SleepHelperDiagnosticResult {
        waitForReply { proxy, finish in
            proxy.acquireClosedLidLease(
                leaseID,
                heartbeatTimeout: heartbeatTimeout
            ) { succeeded, message in
                finish(
                    succeeded
                        ? .success(message ?? "lease acquired")
                        : .failure(
                            message ?? "helper rejected the lease"))
            }
        }
    }

    func releaseLease(
        _ leaseID: String
    ) -> SleepHelperDiagnosticResult {
        waitForReply { proxy, finish in
            proxy.releaseClosedLidLease(leaseID) {
                succeeded,
                message in
                finish(
                    succeeded
                        ? .success(message ?? "lease released")
                        : .failure(
                            message ?? "helper could not release the lease"))
            }
        }
    }

    private func waitForReply(
        _ operation: (
            AIQuotaBarSleepHelperProtocol,
            @escaping (SleepHelperDiagnosticResult) -> Void
        ) -> Void
    ) -> SleepHelperDiagnosticResult {
        let reply = SynchronousReply()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({
            error in
            reply.finish(.failure(error.localizedDescription))
        }) as? AIQuotaBarSleepHelperProtocol else {
            return .failure("could not create the XPC proxy")
        }

        operation(proxy) { result in
            reply.finish(result)
        }
        return reply.wait(timeout: 8)
    }
}

private final class SynchronousReply: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: SleepHelperDiagnosticResult?

    func finish(_ result: SleepHelperDiagnosticResult) {
        lock.lock()
        defer { lock.unlock() }
        guard self.result == nil else { return }
        self.result = result
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> SleepHelperDiagnosticResult {
        guard semaphore.wait(
            timeout: .now() + timeout) == .success else {
            return .failure("timed out waiting for the helper")
        }
        lock.lock()
        defer { lock.unlock() }
        return result ?? .failure("helper returned no result")
    }
}
