import CoreGraphics
import Foundation
import IOKit
import OSLog

protocol DisplayBrightnessControlling: AnyObject {
    /// Reads the current user brightness of the built-in display, or nil
    /// when the platform refuses to report one.
    func currentBrightness() -> Float?

    /// Applies a user brightness value to every built-in display.
    func setBrightness(_ value: Float)
}

protocol LidStateProviding: AnyObject {
    func isLidClosed() -> Bool
}

/// Sets built-in display brightness through the private DisplayServices
/// framework.  The legacy CoreDisplay brightness entry points stopped
/// working on recent macOS releases; DisplayServices is the interface
/// MonitorControl drives for Apple displays on the same systems.
final class DisplayServicesBrightnessController: DisplayBrightnessControlling {
    private typealias GetBrightness = @convention(c) (
        CGDirectDisplayID, UnsafeMutablePointer<Float>
    ) -> Int32
    private typealias SetBrightness = @convention(c) (
        CGDirectDisplayID, Float
    ) -> Int32

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/DisplayServices.framework/"
            + "DisplayServices"

    private var getBrightness: GetBrightness?
    private var setBrightness: SetBrightness?

    private func loadSymbols() -> Bool {
        if getBrightness != nil { return true }
        guard let handle = dlopen(Self.frameworkPath, RTLD_LAZY),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness") else {
            return false
        }
        getBrightness = unsafeBitCast(get, to: GetBrightness.self)
        setBrightness = unsafeBitCast(set, to: SetBrightness.self)
        return true
    }

    private var builtinDisplayIDs: [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count)
            == .success else {
            return []
        }
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) != 0 }
    }

    func currentBrightness() -> Float? {
        guard loadSymbols(), let displayID = builtinDisplayIDs.first else {
            return nil
        }
        var value: Float = -1
        guard let getBrightness,
              getBrightness(displayID, &value) == 0 else {
            return nil
        }
        return value
    }

    func setBrightness(_ value: Float) {
        guard loadSymbols() else { return }
        for displayID in builtinDisplayIDs {
            _ = setBrightness?(displayID, value)
        }
    }
}

/// Reads the live lid state from the IOPMrootDomain IORegistry entry, which
/// publishes the clamshell state as a boolean property on Apple portables.
final class IOPMClamshellLidStateProvider: LidStateProviding {
    private static let clamshellKey = "AppleClamshellState" as CFString

    func isLidClosed() -> Bool {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard let rawValue = IORegistryEntryCreateCFProperty(
            service,
            Self.clamshellKey,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Bool else {
            return false
        }
        return rawValue
    }
}

/// Dims the built-in display while the machine keeps working with the lid
/// closed, and restores the previous brightness once the lid opens or the
/// closed-lid protection ends.  External displays are never touched: they
/// are the screens the user keeps working on in closed-lid mode.
@MainActor
final class ClosedLidBrightnessController {
    private static let dimmedBrightness: Float = 0
    private static let pollInterval: TimeInterval = 2
    private static let savedBrightnessKey = "closedLidDimSavedBrightness"

    private let brightness: DisplayBrightnessControlling
    private let lidState: LidStateProviding
    private let defaults: UserDefaults
    private let logger = Logger(
        subsystem: "com.techfanseric.aiquotabar",
        category: "ClosedLidBrightness"
    )

    private(set) var isArmed = false
    private(set) var isDimmed = false
    private var pollTimer: Timer?

    init(
        brightness: DisplayBrightnessControlling =
            DisplayServicesBrightnessController(),
        lidState: LidStateProviding = IOPMClamshellLidStateProvider(),
        defaults: UserDefaults = .standard
    ) {
        self.brightness = brightness
        self.lidState = lidState
        self.defaults = defaults
    }

    /// Arms or disarms lid monitoring.  Arming starts polling the lid state
    /// so the display dims shortly after the lid actually closes; disarming
    /// restores any dimmed brightness right away.
    func setArmed(_ armed: Bool) {
        guard isArmed != armed else { return }
        isArmed = armed
        if armed {
            startPolling()
            refresh()
        } else {
            stopPolling()
            restoreIfNeeded(reason: "disarmed")
        }
    }

    /// Restores any dimmed brightness and stops monitoring.  Called when the
    /// closed-lid feature tears down so the display is never left at minimum.
    func stop() {
        isArmed = false
        stopPolling()
        restoreIfNeeded(reason: "stopped")
    }

    /// Restores brightness left dimmed by a previous session that exited
    /// before it could restore itself (crash or force quit).  While the lid
    /// is still closed the pending value is kept so the next dim does not
    /// lose the original level.
    func recoverPendingRestore() {
        guard !isDimmed,
              defaults.object(forKey: Self.savedBrightnessKey) != nil,
              !lidState.isLidClosed() else {
            return
        }
        performRestore(reason: "recovered after restart")
    }

    func refresh() {
        guard isArmed else { return }
        if lidState.isLidClosed() {
            dimIfNeeded()
        } else {
            restoreIfNeeded(reason: "lid opened")
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.pollInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        timer.tolerance = 1
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func dimIfNeeded() {
        if isDimmed {
            reassertDimmedBrightness()
            return
        }
        // Never dim blind: without a reading there is nothing to restore.
        guard let current = brightness.currentBrightness() else {
            logger.notice(
                "Could not read built-in brightness; skipping closed-lid dim"
            )
            return
        }
        // A pending value survives a crashed session; keep it instead of
        // overwriting it with the brightness of the already-dark panel.
        if defaults.object(forKey: Self.savedBrightnessKey) == nil {
            defaults.set(
                current,
                forKey: Self.savedBrightnessKey
            )
        }
        brightness.setBrightness(Self.dimmedBrightness)
        isDimmed = true
        logger.notice(
            "Lid closed: dimmed built-in display from \(current)"
        )
    }

    /// macOS may raise the brightness again on its own (ambient-light
    /// adjustment), so a dimmed display is re-dimmed on every poll while the
    /// lid stays closed.
    private func reassertDimmedBrightness() {
        guard let current = brightness.currentBrightness(),
              current > Self.dimmedBrightness else {
            return
        }
        brightness.setBrightness(Self.dimmedBrightness)
        logger.notice(
            "Re-dimmed built-in display after an external brightness change"
        )
    }

    private func restoreIfNeeded(reason: String) {
        guard isDimmed else { return }
        performRestore(reason: reason)
    }

    private func performRestore(reason: String) {
        isDimmed = false
        guard let saved = defaults.object(
            forKey: Self.savedBrightnessKey
        ) as? Float else {
            return
        }
        defaults.removeObject(forKey: Self.savedBrightnessKey)
        brightness.setBrightness(saved)
        logger.notice(
            "\(reason, privacy: .public): restored built-in brightness to \(saved)"
        )
    }
}
