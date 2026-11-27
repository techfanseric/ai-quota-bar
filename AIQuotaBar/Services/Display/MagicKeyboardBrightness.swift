import Foundation
import IOKit.hidsystem

/// Normalize the brightness usages on Bluetooth keyboards verified to emit the
/// Apple vendor keyboard page instead of the built-in keyboard's top-case page.
final class MagicKeyboardBrightness {
    typealias Mapping = [String: Any]
    static let source = "HIDKeyboardModifierMappingSrc"
    static let destination = "HIDKeyboardModifierMappingDst"
    static let pairs: [Mapping] = [
        [source: 0xff0100000021, destination: 0x00ff00000005],
        [source: 0xff0100000020, destination: 0x00ff00000004],
    ]

    private var client: IOHIDEventSystemClient?
    private var installed: [UInt64: [Mapping]] = [:]

    static func additions(to mappings: [Mapping]) -> [Mapping] {
        let sources = Set(mappings.compactMap { $0[source] as? Int })
        return pairs.filter { pair in
            guard let usage = pair[source] as? Int else { return false }
            return !sources.contains(usage)
        }
    }

    // Called on startup and on the controller's maintenance timer. Use the
    // service registry ID so a reconnect is recognized as a new connection.
    func reconcile(removing: Bool = false) {
        if removing && installed.isEmpty { client = nil; return }
        if client == nil { client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault) }
        guard let client, let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else { return }
        var connected = Set<UInt64>()
        for service in services where IOHIDServiceClientConformsTo(service, 1, 6) != 0 {
            func property(_ key: String) -> Any? { IOHIDServiceClientCopyProperty(service, key as CFString) }
            guard (property("VendorID") as? NSNumber)?.intValue == 76,
                  let product = property("ProductID") as? NSNumber, [615, 666].contains(product.intValue),
                  let id = (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value else { continue }
            connected.insert(id)
            if removing && installed[id] == nil { continue }
            let raw = property("UserKeyMapping")
            guard raw == nil || raw is [Mapping] else { continue }
            let current = raw as? [Mapping] ?? []
            let owned = installed[id] ?? []
            let desired: [Mapping]
            let added = removing ? [] : Self.additions(to: current)
            if removing {
                desired = current.filter { item in !owned.contains { NSDictionary(dictionary: $0).isEqual(to: item) } }
            } else {
                desired = current + added
            }
            guard desired.count != current.count,
                  IOHIDServiceClientSetProperty(service, "UserKeyMapping" as CFString, desired as CFArray) else { continue }
            if !removing {
                installed[id] = owned + added.filter { pair in !owned.contains { NSDictionary(dictionary: $0).isEqual(to: pair) } }
            }
        }
        installed = removing ? [:] : installed.filter { connected.contains($0.key) }
        if removing { self.client = nil }
    }
}
