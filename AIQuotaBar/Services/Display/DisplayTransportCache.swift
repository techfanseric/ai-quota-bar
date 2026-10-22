import Foundation

/// IOAVServiceCreateWithService can wait indefinitely for a disappearing DCP
/// service. Keep that wait off the caller and never start duplicate opens for it.
final class DisplayTransportCache<Key: Hashable, Value> {
    private struct Entry {
        var pending = true
        var value: Value?
        var retryAfter = Date.distantPast
    }
    private let condition = NSCondition()
    private let queue = DispatchQueue(label: "display.transport.open", qos: .utility, attributes: .concurrent)
    private var entries: [Key: Entry] = [:]
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 0.15) { self.timeout = timeout }

    func resolve(_ key: Key, create: @escaping () -> Value?) -> Value? {
        condition.lock()
        defer { condition.unlock() }
        if let value = entries[key]?.value { return value }
        if entries[key] == nil || (entries[key]?.pending == false && entries[key]!.retryAfter < Date()) {
            guard entries.values.filter({ $0.pending }).count < 8 else { return nil }
            entries[key] = Entry()
            queue.async { [self] in
                let value = create()
                condition.lock()
                entries[key] = Entry(pending: false, value: value, retryAfter: Date().addingTimeInterval(1))
                condition.broadcast()
                condition.unlock()
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while entries[key]?.pending == true {
            if !condition.wait(until: deadline) { return nil }
        }
        return entries[key]?.value
    }

    func invalidate(_ key: Key) {
        condition.lock()
        // A stuck open stays pending: retrying must not leak a thread per keypress.
        if entries[key]?.value != nil { entries[key] = Entry(pending: false, retryAfter: Date().addingTimeInterval(0.5)) }
        condition.unlock()
    }
}
