import Foundation
import IOKit.pwr_mgt

protocol PowerAssertionControlling: AnyObject {
    var isHoldingAssertions: Bool { get }
    func acquire(keepDisplayAwake: Bool, declareUserActivity: Bool) throws
    func update(keepDisplayAwake: Bool, declareUserActivity: Bool) throws
    func release()
}

enum PowerAssertionError: LocalizedError {
    case createFailed(type: String, code: IOReturn)
    case userActivityFailed(code: IOReturn)

    var errorDescription: String? {
        switch self {
        case let .createFailed(type, code):
            return "Could not create \(type) power assertion (IOReturn \(code))."
        case let .userActivityFailed(code):
            return "Could not declare user activity (IOReturn \(code))."
        }
    }
}

final class PowerAssertionController: PowerAssertionControlling {
    private static let reason = "AI Quota Bar: Codex is working"
    // A declared user activity only suppresses the screen saver for a few
    // seconds, so it must be re-declared well under the shortest plausible
    // screen-saver timer. 45s keeps a working margin below one minute.
    private static let activityRefreshInterval: TimeInterval = 45

    private var systemSleepAssertion: IOPMAssertionID = 0
    private var displaySleepAssertion: IOPMAssertionID = 0
    private var userActivityAssertion: IOPMAssertionID = 0
    private var activityTimer: Timer?
    private var shouldKeepDisplayAwake = false
    private var shouldDeclareUserActivity = false

    var isHoldingAssertions: Bool {
        systemSleepAssertion != 0
    }

    func acquire(keepDisplayAwake: Bool, declareUserActivity: Bool) throws {
        if isHoldingAssertions {
            try update(
                keepDisplayAwake: keepDisplayAwake,
                declareUserActivity: declareUserActivity
            )
            return
        }

        do {
            systemSleepAssertion = try createAssertion(
                type: kIOPMAssertPreventUserIdleSystemSleep as CFString,
                label: "system sleep"
            )
            shouldKeepDisplayAwake = keepDisplayAwake
            shouldDeclareUserActivity = declareUserActivity
            try applyDisplayPolicy()
        } catch {
            release()
            throw error
        }
    }

    func update(keepDisplayAwake: Bool, declareUserActivity: Bool) throws {
        guard isHoldingAssertions else {
            try acquire(
                keepDisplayAwake: keepDisplayAwake,
                declareUserActivity: declareUserActivity
            )
            return
        }

        shouldKeepDisplayAwake = keepDisplayAwake
        shouldDeclareUserActivity = declareUserActivity
        try applyDisplayPolicy()
    }

    func release() {
        activityTimer?.invalidate()
        activityTimer = nil
        releaseAssertion(&userActivityAssertion)
        releaseAssertion(&displaySleepAssertion)
        releaseAssertion(&systemSleepAssertion)
        shouldKeepDisplayAwake = false
        shouldDeclareUserActivity = false
    }

    private func applyDisplayPolicy() throws {
        if shouldKeepDisplayAwake {
            if displaySleepAssertion == 0 {
                displaySleepAssertion = try createAssertion(
                    type: kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                    label: "display sleep"
                )
            }
        } else {
            releaseAssertion(&displaySleepAssertion)
        }

        if shouldKeepDisplayAwake && shouldDeclareUserActivity {
            try refreshUserActivity()
            if activityTimer == nil {
                activityTimer = Timer.scheduledTimer(
                    withTimeInterval: Self.activityRefreshInterval,
                    repeats: true
                ) { [weak self] _ in
                    try? self?.refreshUserActivity()
                }
                activityTimer?.tolerance = 2
            }
        } else {
            activityTimer?.invalidate()
            activityTimer = nil
            releaseAssertion(&userActivityAssertion)
        }
    }

    private func createAssertion(type: CFString, label: String) throws -> IOPMAssertionID {
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.reason as CFString,
            &assertionID
        )
        guard result == kIOReturnSuccess else {
            throw PowerAssertionError.createFailed(type: label, code: result)
        }
        return assertionID
    }

    private func refreshUserActivity() throws {
        let result = IOPMAssertionDeclareUserActivity(
            Self.reason as CFString,
            kIOPMUserActiveLocal,
            &userActivityAssertion
        )
        guard result == kIOReturnSuccess else {
            throw PowerAssertionError.userActivityFailed(code: result)
        }
    }

    private func releaseAssertion(_ assertionID: inout IOPMAssertionID) {
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
    }

    deinit {
        release()
    }
}
