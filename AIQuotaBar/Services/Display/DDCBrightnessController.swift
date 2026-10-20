import CoreGraphics
import Foundation
import IOKit

// CoreDisplay left the filesystem on recent macOS releases (it only exists
// inside the dyld shared cache), so dlopen-by-path fails and the display
// info-dictionary entry point must be bound at link time instead.  The
// package links the private framework weakly for this symbol.
@_silgen_name("CoreDisplay_DisplayCreateInfoDictionary")
private func coreDisplayCreateInfoDictionary(
    _ displayID: CGDirectDisplayID
) -> CFDictionary?

// MARK: - DDC/CI packet construction (pure, unit-testable)

/// Builds DDC/CI VCP packets for arbitrary codes and parses replies.  The
/// wire format follows the DDC/CI specification as implemented by m1ddc
/// (MIT, waydabber): a get request is written first and the reply is then
/// read back; a set command is written twice because some panels drop the
/// first packet while their DDC engine wakes up.
enum DDCPacketBuilder {
    static let luminanceCode: UInt8 = 0x10
    static let defaultChipAddress: UInt32 = 0x37
    static let hostAddress: UInt8 = 0x51

    static func getRequest(code: UInt8) -> [UInt8] {
        var request = [UInt8](repeating: 0, count: 4)
        request[0] = 0x82
        request[1] = 0x01
        request[2] = code
        request[3] = 0x6e ^ request[0] ^ request[1] ^ request[2]
            ^ request[3]
        return request
    }

    static func setCommand(code: UInt8, value: Int) -> [UInt8] {
        let clamped = max(0, min(value, 0xFFFF))
        var command = [UInt8](repeating: 0, count: 6)
        command[0] = 0x84
        command[1] = 0x03
        command[2] = code
        command[3] = UInt8((clamped >> 8) & 0xFF)
        command[4] = UInt8(clamped & 0xFF)
        command[5] = 0x6E ^ hostAddress ^ command[0] ^ command[1]
            ^ command[2] ^ command[3] ^ command[4]
        return command
    }

    static func getLuminanceRequest() -> [UInt8] {
        getRequest(code: luminanceCode)
    }

    static func setLuminanceCommand(value: Int) -> [UInt8] {
        setCommand(code: luminanceCode, value: value)
    }

    /// A get-VCP reply carries the maximum value at bytes 6..7 and the
    /// current value at bytes 8..9, both big-endian.  Replies with a zero
    /// maximum or an out-of-range current value are treated as garbage
    /// (slow panels return stale buffers while waking up).
    static func parseLuminanceReply(
        _ reply: [UInt8]
    ) -> (current: Int, maximum: Int)? {
        guard reply.count >= 10 else { return nil }
        let maximum = (Int(reply[6]) << 8) | Int(reply[7])
        let current = (Int(reply[8]) << 8) | Int(reply[9])
        guard maximum > 0, current <= maximum else { return nil }
        return (current, maximum)
    }
}

// MARK: - External display brightness over DDC

/// Only luminance is captured or written. Optional legacy fields remain
/// decodable so pending brightness restores survive upgrades, but are ignored.
struct ExternalDisplayState: Codable, Equatable {
    var luminance: Int
    var maximumLuminance: Int? = nil
    var contrast: Int? = nil
    var redGain: Int? = nil
    var greenGain: Int? = nil
    var blueGain: Int? = nil

    /// Percentages use the panel's reported range, not an assumed 0...100.
    /// Dimming never raises a display already below the requested target.
    func dimmedLuminance(targetPercent: Double) -> Int {
        let percent = targetPercent.isFinite ? min(100, max(0, targetPercent)) : 0
        let maximum = max(1, maximumLuminance ?? 100)
        return min(luminance, Int((Double(maximum) * percent / 100).rounded()))
    }

    var isMeaningful: Bool {
        luminance >= 0
    }
}

struct ExternalDDCDisplay {
    let displayID: CGDirectDisplayID
    let name: String
    /// Stable identity used to persist per-display values across relaunches.
    let persistenceKey: String
    let avService: CFTypeRef
    let chipAddress: UInt32
    var transportKey: UInt64? = nil
}

protocol ExternalDisplayBrightnessControlling: AnyObject {
    /// Enumerates external displays reachable over DDC.  Blocking.
    func enumerateTargets() -> [ExternalDDCDisplay]

    /// Reads the dimmable levels of a display.  Values are read twice and
    /// must agree (flaky panels return garbage while waking up).  Blocking.
    func readState(
        of target: ExternalDDCDisplay
    ) -> ExternalDisplayState?

    /// Lowers hardware luminance to the selected percentage with read-back retries.
    /// Contrast and color gains are never changed. Blocking.
    func applyDimmedState(
        to target: ExternalDDCDisplay,
        original: ExternalDisplayState,
        targetPercent: Double
    )

    /// Restores captured levels with read-back retries.  Blocking.
    func applyState(
        _ state: ExternalDisplayState,
        of target: ExternalDDCDisplay
    )
    /// Interactive key adjustment: report transport failure without repeated verification.
    func setLuminance(_ state: ExternalDisplayState, of target: ExternalDDCDisplay) -> Bool

}

extension ExternalDisplayBrightnessControlling {
    func setLuminance(_ state: ExternalDisplayState, of target: ExternalDDCDisplay) -> Bool {
        applyState(state, of: target)
        return true
    }
}

/// DDC/CI brightness transport for external displays on Apple Silicon,
/// built on the private IOAVService I2C interface (the same interface the
/// m1ddc utility and MonitorControl drive).  All calls block for tens of
/// milliseconds; callers should keep them off the main thread.
final class DDCBrightnessController: ExternalDisplayBrightnessControlling {
    private typealias IOAVServiceCreateWithServiceFn = @convention(c) (
        CFAllocator?, io_service_t
    ) -> CFTypeRef?
    private typealias IOAVServiceReadI2CFn = @convention(c) (
        CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32
    ) -> Int32
    private typealias IOAVServiceWriteI2CFn = @convention(c) (
        CFTypeRef, UInt32, UInt32, UnsafeRawPointer, UInt32
    ) -> Int32

    private static let transports = DisplayTransportCache<UInt64, CFTypeRef>()

    private static let ddcWaitMicroseconds: useconds_t = 10_000
    private static let readRetryDelayMicroseconds: useconds_t = 40_000
    private static let readRetryCount = 4
    private static let writeIterations = 2
    private static let stableReadRounds = 2
    private static let stableReadGapMicroseconds: useconds_t = 20_000
    private static let dimAttempts = 2
    private static let restoreAttempts = 3
    private static let dimVerifyDelayMicroseconds: useconds_t = 120_000
    private var avServiceCreateWithService: IOAVServiceCreateWithServiceFn?
    private var avServiceReadI2C: IOAVServiceReadI2CFn?
    private var avServiceWriteI2C: IOAVServiceWriteI2CFn?

    private func loadSymbols() -> Bool {
        if avServiceReadI2C != nil { return true }
        let iokit = dlopen(
            "/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        guard let createSvcPtr = dlsym(iokit, "IOAVServiceCreateWithService"),
              let readPtr = dlsym(iokit, "IOAVServiceReadI2C"),
              let writePtr = dlsym(iokit, "IOAVServiceWriteI2C") else {
            return false
        }
        avServiceCreateWithService = unsafeBitCast(
            createSvcPtr, to: IOAVServiceCreateWithServiceFn.self)
        avServiceReadI2C = unsafeBitCast(readPtr, to: IOAVServiceReadI2CFn.self)
        avServiceWriteI2C = unsafeBitCast(
            writePtr, to: IOAVServiceWriteI2CFn.self)
        return true
    }

    func enumerateTargets() -> [ExternalDDCDisplay] {
        guard loadSymbols(), let avServiceCreateWithService else { return [] }

        var onlineIDs = [CGDirectDisplayID](
            repeating: 0, count: 16)
        var onlineCount: UInt32 = 0
        guard CGGetOnlineDisplayList(
            UInt32(onlineIDs.count), &onlineIDs, &onlineCount)
            == .success else { return [] }

        // Pair every display with its framebuffer registry entry so the
        // DCPAVServiceProxy walk below can attribute proxies to displays.
        var displayEntries: [(entryID: UInt64, display: CGDirectDisplayID, name: String)] = []
        for displayID in onlineIDs.prefix(Int(onlineCount)) {
            guard let info = coreDisplayCreateInfoDictionary(displayID),
                  let raw = CFDictionaryGetValue(
                    info,
                    Unmanaged.passUnretained(
                        "IODisplayLocation" as CFString).toOpaque())
            else { continue }
            let location = unsafeBitCast(raw, to: CFString.self)
            let adapter = IORegistryEntryCopyFromPath(
                kIOMainPortDefault, location)
            guard adapter != 0 else { continue }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(adapter, &entryID)
            let name = displayProductName(adapter: adapter)
                ?? "Display 0x\(String(displayID, radix: 16))"
            IOObjectRelease(adapter)
            displayEntries.append((entryID, displayID, name))
        }
        guard !displayEntries.isEmpty else { return [] }

        // Walk the service plane: remember the framebuffer that most
        // recently matched a display, then attach DCPAVServiceProxy
        // services that follow it (m1ddc's getDisplayDDCTransport walk).
        var matchedEntryID: UInt64 = 0
        var serviceByEntry: [UInt64: (avService: CFTypeRef, chip: UInt32, key: UInt64)] = [:]
        var iterator: io_iterator_t = 0
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return [] }
        defer { IOObjectRelease(root) }
        guard IORegistryEntryCreateIterator(
            root,
            kIOServicePlane,
            UInt32(kIORegistryIterateRecursively),
            &iterator) == KERN_SUCCESS else { return [] }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if IOObjectConformsTo(service, "IOMobileFramebuffer") != 0 {
                var entryID: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(service, &entryID)
                matchedEntryID = displayEntries.contains {
                    $0.entryID == entryID
                } ? entryID : 0
            } else if matchedEntryID != 0,
                      serviceByEntry[matchedEntryID] == nil,
                      IOObjectConformsTo(service, "DCPAVServiceProxy") != 0 {
                let location = IORegistryEntrySearchCFProperty(
                    service, kIOServicePlane, "Location" as CFString,
                    kCFAllocatorDefault, 0) as? String
                if location == "External" {
                    // Retain across the background open, even if the caller times out.
                    var transportKey: UInt64 = 0
                    IORegistryEntryGetRegistryEntryID(service, &transportKey)
                    let retainedService = service
                    IOObjectRetain(retainedService)
                    let lease = DisplayRegistryLease(retainedService)
                    if let avService = Self.transports.resolve(transportKey, create: {
                        avServiceCreateWithService(nil, lease.service)
                    }) {
                        serviceByEntry[matchedEntryID] = (avService, chipAddress(for: service), transportKey)
                    }
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        IOObjectRelease(iterator)

        return displayEntries.compactMap { entry in
            guard let transport = serviceByEntry[entry.entryID] else {
                return nil
            }
            let vendor = CGDisplayVendorNumber(entry.display)
            let model = CGDisplayModelNumber(entry.display)
            let serial = CGDisplaySerialNumber(entry.display)
            return ExternalDDCDisplay(
                displayID: entry.display,
                name: entry.name,
                persistenceKey: "ddc-\(vendor)-\(model)-\(serial)",
                avService: transport.avService,
                chipAddress: transport.chip, transportKey: transport.key)
        }
    }

    private func displayProductName(adapter: io_service_t) -> String? {
        guard let attrs = IORegistryEntrySearchCFProperty(
            adapter, kIOServicePlane, "DisplayAttributes" as CFString,
            kCFAllocatorDefault, UInt32(kIORegistryIterateRecursively)),
            let attributes = attrs as? [String: Any],
            let product = attributes["ProductAttributes"] as? [String: Any],
            let name = product["ProductName"] as? String else {
            return nil
        }
        return name
    }

    /// MCDP29xx-based docks route DDC through a different chip address.
    private func chipAddress(for proxy: io_service_t) -> UInt32 {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(
            proxy, kIOServicePlane, &parent) == KERN_SUCCESS else {
            return DDCPacketBuilder.defaultChipAddress
        }
        defer { IOObjectRelease(parent) }
        guard let providerClass = IORegistryEntrySearchCFProperty(
            parent, kIOServicePlane, "EPICProviderClass" as CFString,
            kCFAllocatorDefault, UInt32(kIORegistryIterateRecursively))
            as? String,
            providerClass == "AppleDCPMCDP29XX" else {
            return DDCPacketBuilder.defaultChipAddress
        }
        return 0xB7
    }

    private struct Reading: Equatable {
        let current: Int
        let maximum: Int
    }

    // MARK: Generic VCP transport

    /// One get-request + reply round; nil when the I/O fails or the reply
    /// does not parse.
    private func readOnce(
        _ code: UInt8, of target: ExternalDDCDisplay
    ) -> Reading? {
        guard let avServiceReadI2C, let avServiceWriteI2C else {
            return nil
        }
        let request = DDCPacketBuilder.getRequest(code: code)
        var outgoing = [UInt8](repeating: 0, count: request.count)
        outgoing.replaceSubrange(0..<request.count, with: request)
        guard avServiceWriteI2C(
            target.avService, target.chipAddress,
            UInt32(DDCPacketBuilder.hostAddress), outgoing,
            UInt32(request.count)) == 0 else { return nil }
        usleep(Self.ddcWaitMicroseconds)
        var reply = [UInt8](repeating: 0, count: 32)
        guard avServiceReadI2C(
            target.avService, target.chipAddress,
            UInt32(DDCPacketBuilder.hostAddress), &reply, 12) == 0 else {
            return nil
        }
        guard let value = DDCPacketBuilder.parseLuminanceReply(reply) else { return nil }
        return Reading(current: value.current, maximum: value.maximum)
    }

    /// Retries a read while the panel wakes its DDC engine.
    private func readWithRetry(
        _ code: UInt8, of target: ExternalDDCDisplay
    ) -> Reading? {
        for attempt in 0..<Self.readRetryCount {
            usleep(attempt == 0
                ? Self.ddcWaitMicroseconds
                : Self.readRetryDelayMicroseconds)
            if let value = readOnce(code, of: target) {
                return value
            }
        }
        return nil
    }

    /// Two agreeing reads, or nil.  Flaky panels occasionally return a
    /// plausible-looking but wrong buffer; acting on one of those would dim
    /// from (and restore to) garbage.
    private func readStable(
        _ code: UInt8, of target: ExternalDDCDisplay
    ) -> Reading? {
        for _ in 0..<Self.stableReadRounds {
            let first = readWithRetry(code, of: target)
            guard let first else { continue }
            usleep(Self.stableReadGapMicroseconds)
            let second = readWithRetry(code, of: target)
            if second == first {
                return first
            }
        }
        return nil
    }

    /// Double-issued set command; returns when the I/O itself succeeded.
    private func writeOnce(
        _ code: UInt8, _ value: Int, of target: ExternalDDCDisplay
    ) -> Bool {
        guard let avServiceWriteI2C else { return false }
        let command = DDCPacketBuilder.setCommand(code: code, value: value)
        var outgoing = [UInt8](repeating: 0, count: command.count)
        outgoing.replaceSubrange(0..<command.count, with: command)
        for _ in 0..<Self.writeIterations {
            usleep(Self.ddcWaitMicroseconds)
            guard avServiceWriteI2C(
                target.avService, target.chipAddress,
                UInt32(DDCPacketBuilder.hostAddress), outgoing,
                UInt32(command.count)) == 0 else { return false }
        }
        return true
    }

    func readState(
        of target: ExternalDDCDisplay
    ) -> ExternalDisplayState? {
        guard loadSymbols() else { return nil }
        guard let luminance = readStable(
            DDCPacketBuilder.luminanceCode, of: target) else {
            if let key = target.transportKey { Self.transports.invalidate(key) }
            return nil
        }
        return ExternalDisplayState(
            luminance: luminance.current, maximumLuminance: luminance.maximum)
    }

    func setLuminance(_ state: ExternalDisplayState, of target: ExternalDDCDisplay) -> Bool {
        guard loadSymbols() else { return false }
        let success = writeOnce(DDCPacketBuilder.luminanceCode, state.luminance, of: target)
        if !success, let key = target.transportKey { Self.transports.invalidate(key) }
        return success
    }

    func applyDimmedState(
        to target: ExternalDDCDisplay,
        original: ExternalDisplayState,
        targetPercent: Double
    ) {
        let desired = original.dimmedLuminance(targetPercent: targetPercent)
        guard loadSymbols() else { return }
        for _ in 0..<Self.dimAttempts {
            _ = writeOnce(DDCPacketBuilder.luminanceCode, desired, of: target)
            usleep(Self.dimVerifyDelayMicroseconds)
            if let now = readStable(DDCPacketBuilder.luminanceCode, of: target),
               now.current == desired {
                return
            }
        }
    }

    func applyState(
        _ state: ExternalDisplayState,
        of target: ExternalDDCDisplay
    ) {
        guard loadSymbols() else { return }
        restoreLever(
            DDCPacketBuilder.luminanceCode, value: state.luminance,
            of: target)
    }

    /// Writes a captured value back with read-back retries; the last write
    /// stands even if the panel refuses to echo it (best effort).
    private func restoreLever(
        _ code: UInt8, value: Int, of target: ExternalDDCDisplay
    ) {
        for _ in 0..<Self.restoreAttempts {
            _ = writeOnce(code, value, of: target)
            usleep(Self.dimVerifyDelayMicroseconds)
            if let now = readStable(code, of: target), now.current == value {
                return
            }
        }
    }
}

private final class DisplayRegistryLease {
    let service: io_service_t
    init(_ service: io_service_t) { self.service = service }
    deinit { IOObjectRelease(service) }
}
