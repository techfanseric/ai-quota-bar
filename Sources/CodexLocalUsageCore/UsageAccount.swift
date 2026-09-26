import Foundation

/// A local login observation is evidence about auth.json, not a provider billing receipt.
/// No access/refresh token or raw account identifier is retained or transmitted.
public struct UsageAccountObservation: Codable, Sendable {
    public let at: Date
    public let accountID: String?
    public let label: String?
    public let generation: String?
    public init(at: Date, accountID: String?, label: String? = nil, generation: String?) {
        self.at = at; self.accountID = accountID; self.label = label; self.generation = generation
    }
    public static func read(root: URL, now: Date = Date()) -> Self {
        let url = root.appendingPathComponent("auth.json")
        func unknown() -> Self { .init(at: now, accountID: nil, generation: nil) }
        guard let before = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let size = before.fileSize, size < 262_144,
              let data = try? Data(contentsOf: url),
              let after = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              before.contentModificationDate == after.contentModificationDate, before.fileSize == after.fileSize,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let modified = before.contentModificationDate else { return unknown() }
        guard case let .chatgptLogin(login) = CodexAuthFileReader.interpret(obj) else { return unknown() }
        return .init(at: now, accountID: login.accountDigest, label: login.email,
                     generation: "\(modified.timeIntervalSince1970):\(size)")
    }
}

public struct UsageAccountTimeline: Codable, Sendable {
    public struct Interval: Codable, Sendable {
        var start: Date
        var end: Date
        var accountID: String
    }
    public private(set) var previous: UsageAccountObservation?
    public private(set) var intervals: [Interval] = []
    public private(set) var labels: [String: String] = [:]
    public init() {}
    public mutating func observe(_ sample: UsageAccountObservation) {
        defer { previous = sample }
        if let id = sample.accountID, let label = sample.label, !label.isEmpty { labels[id] = label }
        guard let prior = previous, let id = sample.accountID, prior.accountID == id,
              sample.generation != nil, prior.generation == sample.generation,
              sample.at > prior.at, sample.at.timeIntervalSince(prior.at) <= 90 else { return }
        if let last = intervals.last, last.accountID == id, last.end == prior.at {
            intervals[intervals.count - 1].end = sample.at
        } else { intervals.append(.init(start: prior.at, end: sample.at, accountID: id)) }
    }
    public func account(at time: Date) -> String? {
        // Intervals are chronological, and gaps (restart, sleep, switch) stay unknown.
        var lo = 0, hi = intervals.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if intervals[mid].start <= time { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0, time < intervals[lo - 1].end else { return nil }
        return intervals[lo - 1].accountID
    }
}
