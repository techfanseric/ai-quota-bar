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
    static let contrastCode: UInt8 = 0x12
    static let redGainCode: UInt8 = 0x16
    static let greenGainCode: UInt8 = 0x18
    static let blueGainCode: UInt8 = 0x1A
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

/// The set of VCP levels captured from one external display while stepping
/// away.  Luminance is the baseline lever every DDC panel supports; contrast
/// and the RGB gains are optional — panels lock or clamp them to varying
/// degrees, so a nil means "unreadable, leave this lever alone".
struct ExternalDisplayState: Codable, Equatable {
    var luminance: Int
    var contrast: Int?
    var redGain: Int?
    var greenGain: Int?
    var blueGain: Int?

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
}

protocol ExternalDisplayBrightnessControlling: AnyObject {
    /// Enumerates external displays reachable over DDC.  Blocking.
    func enumerateTargets() -> [ExternalDDCDisplay]

    /// Reads the dimmable levels of a display.  Values are read twice and
    /// must agree (flaky panels return garbage while waking up).  Blocking.
    func readState(
        of target: ExternalDDCDisplay
    ) -> ExternalDisplayState?

    /// Drives a display as dark as it allows: luminance to 0, then contrast
    /// and RGB gains where the panel actually accepts them (a lever whose
    /// read-back stays above half of its original value is skipped rather
    /// than churned).  Blocking.
    func applyDimmedState(
        to target: ExternalDDCDisplay,
        original: ExternalDisplayState
    )

    /// Restores captured levels with read-back retries.  Blocking.
    func applyState(
        _ state: ExternalDisplayState,
        of target: ExternalDDCDisplay
    )
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

    private static let ddcWaitMicroseconds: useconds_t = 10_000
    private static let readRetryDelayMicroseconds: useconds_t = 40_000
    private static let readRetryCount = 4
    private static let writeIterations = 2
    private static let stableReadRounds = 2
    private static let stableReadGapMicroseconds: useconds_t = 20_000
    private static let dimAttempts = 2
    private static let restoreAttempts = 3
    private static let dimVerifyDelayMicroseconds: useconds_t = 120_000
    private static let capabilitiesPrefix = "ddcLeverCapabilities."

    /// VCP codes a panel accepted dimming on, keyed by persistence key.
    /// Locked levers (like the RV200's gains) are probed once per persisted
    /// entry and skipped instantly afterwards.
    private var leverCapabilities: [String: Set<UInt8>] = [:]
    private let capabilitiesLock = NSLock()
    private let capabilitiesDefaults: UserDefaults?

    init(capabilitiesDefaults: UserDefaults? = .standard) {
        self.capabilitiesDefaults = capabilitiesDefaults
        loadLeverCapabilities()
    }

    private static let allCapabilityNames: [(code: UInt8, name: String)] = [
        (DDCPacketBuilder.luminanceCode, "luminance"),
        (DDCPacketBuilder.contrastCode, "contrast"),
        (DDCPacketBuilder.redGainCode, "redGain"),
        (DDCPacketBuilder.greenGainCode, "greenGain"),
        (DDCPacketBuilder.blueGainCode, "blueGain"),
    ]

    private static func name(ofCode code: UInt8) -> String? {
        Self.allCapabilityNames.first { $0.code == code }?.name
    }

    private func loadLeverCapabilities() {
        guard let capabilitiesDefaults else { return }
        let prefix = Self.capabilitiesPrefix
        for (key, value) in capabilitiesDefaults.dictionaryRepresentation()
        where key.hasPrefix(prefix) {
            guard let names = value as? [String] else { continue }
            let codes = Set(names.compactMap { name in
                Self.allCapabilityNames.first { $0.name == name }?.code
            })
            leverCapabilities[String(key.dropFirst(prefix.count))] = codes
        }
    }

    /// nil means "never probed"; an empty set means no lever moves.
    private func knownCapabilities(for key: String) -> Set<UInt8>? {
        capabilitiesLock.lock()
        defer { capabilitiesLock.unlock() }
        return leverCapabilities[key]
    }

    private func rememberLever(
        _ code: UInt8, accepted: Bool, for key: String
    ) {
        capabilitiesLock.lock()
        if accepted {
            leverCapabilities[key, default: []].insert(code)
        } else {
            leverCapabilities[key, default: []].remove(code)
        }
        let names = leverCapabilities[key].map { codes in
            codes.compactMap(Self.name(ofCode:)).sorted()
        }
        capabilitiesLock.unlock()

        guard let capabilitiesDefaults, let names else { return }
        capabilitiesDefaults.set(
            names, forKey: Self.capabilitiesPrefix + key)
    }

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
        var serviceByEntry: [UInt64: (avService: CFTypeRef, chip: UInt32)] = [:]
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            IORegistryGetRootEntry(kIOMainPortDefault),
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
                if location == "External",
                   let avService = avServiceCreateWithService(nil, service) {
                    serviceByEntry[matchedEntryID] = (
                        avService,
                        chipAddress(for: service)
                    )
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
                chipAddress: transport.chip)
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

    // MARK: Generic VCP transport

    /// One get-request + reply round; nil when the I/O fails or the reply
    /// does not parse.
    private func readOnce(
        _ code: UInt8, of target: ExternalDDCDisplay
    ) -> Int? {
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
        return DDCPacketBuilder.parseLuminanceReply(reply)?.current
    }

    /// Retries a read while the panel wakes its DDC engine.
    private func readWithRetry(
        _ code: UInt8, of target: ExternalDDCDisplay
    ) -> Int? {
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
    ) -> Int? {
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
            return nil
        }
        return ExternalDisplayState(
            luminance: luminance,
            contrast: readStable(DDCPacketBuilder.contrastCode, of: target),
            redGain: readStable(DDCPacketBuilder.redGainCode, of: target),
            greenGain: readStable(
                DDCPacketBuilder.greenGainCode, of: target),
            blueGain: readStable(
                DDCPacketBuilder.blueGainCode, of: target))
    }

    func applyDimmedState(
        to target: ExternalDDCDisplay,
        original: ExternalDisplayState
    ) {
        guard loadSymbols() else { return }
        dimLever(
            DDCPacketBuilder.luminanceCode,
            originalValue: original.luminance,
            of: target)
        for (originalValue, code) in [
            (original.contrast, DDCPacketBuilder.contrastCode),
            (original.redGain, DDCPacketBuilder.redGainCode),
            (original.greenGain, DDCPacketBuilder.greenGainCode),
            (original.blueGain, DDCPacketBuilder.blueGainCode),
        ] {
            guard let originalValue, originalValue > 0 else { continue }
            dimLever(code, originalValue: originalValue, of: target)
        }
    }

    /// Writes 0 and keeps the result only when the panel moved to at most
    /// half of the original level.  Panels that clamp (contrast floor 25 on
    /// the RV200) or lock levers entirely (RV200 gains) are detected by the
    /// read-back and left alone instead of being churned pointlessly.  Once
    /// a lever has been probed its outcome is cached, so later dims skip
    /// locked levers without any DDC round-trip.
    private func dimLever(
        _ code: UInt8, originalValue: Int, of target: ExternalDDCDisplay
    ) {
        guard originalValue > 0 else { return }
        // Luminance is the baseline lever: a transient DDC hiccup must not
        // permanently stop a display from dimming, so only the optional
        // levers honour the cache skip.
        if code != DDCPacketBuilder.luminanceCode,
           let known = knownCapabilities(for: target.persistenceKey),
           !known.contains(code) {
            return
        }
        var accepted = false
        for _ in 0..<Self.dimAttempts {
            _ = writeOnce(code, 0, of: target)
            usleep(Self.dimVerifyDelayMicroseconds)
            if let now = readStable(code, of: target),
               now <= originalValue / 2 {
                accepted = true
                break
            }
        }
        rememberLever(code, accepted: accepted, for: target.persistenceKey)
    }

    func applyState(
        _ state: ExternalDisplayState,
        of target: ExternalDDCDisplay
    ) {
        guard loadSymbols() else { return }
        restoreLever(
            DDCPacketBuilder.luminanceCode, value: state.luminance,
            of: target)
        for (value, code) in [
            (state.contrast, DDCPacketBuilder.contrastCode),
            (state.redGain, DDCPacketBuilder.redGainCode),
            (state.greenGain, DDCPacketBuilder.greenGainCode),
            (state.blueGain, DDCPacketBuilder.blueGainCode),
        ] {
            guard let value else { continue }
            restoreLever(code, value: value, of: target)
        }
    }

    /// Writes a captured value back with read-back retries; the last write
    /// stands even if the panel refuses to echo it (best effort).
    private func restoreLever(
        _ code: UInt8, value: Int, of target: ExternalDDCDisplay
    ) {
        for _ in 0..<Self.restoreAttempts {
            _ = writeOnce(code, value, of: target)
            usleep(Self.dimVerifyDelayMicroseconds)
            if let now = readStable(code, of: target), now == value {
                return
            }
        }
    }
}
