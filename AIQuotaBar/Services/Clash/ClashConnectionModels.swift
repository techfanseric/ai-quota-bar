import Foundation

struct ClashConnectionsResponse: Decodable, Equatable, Sendable {
    let downloadTotal: Int64?
    let uploadTotal: Int64?
    let connections: [ClashConnectionRecord]
}

struct ClashConnectionRecord: Decodable, Equatable, Sendable {
    let id: String
    let download: Int64
    let upload: Int64
    let chains: [String]
    let rule: String?
    let rulePayload: String?
    let start: String
    let metadata: ClashConnectionMetadata
}

struct ClashConnectionMetadata: Decodable, Equatable, Sendable {
    let network: String?
    let type: String?
    let destinationIP: String?
    let host: String?
    let process: String?
    let processPath: String?
    let remoteDestination: String?
    let sniffHost: String?
}

struct ClashActiveConnection: Identifiable, Equatable, Sendable {
    let id: String
    let host: String
    let process: String?
    let network: String?
    let chains: [String]
    let startedAt: Date?
    let duration: TimeInterval
    let uploadSpeed: Double
    let downloadSpeed: Double

    var primaryChain: String? {
        chains.first
    }
}

struct ClashConnectionActivitySnapshot: Equatable, Sendable {
    let observedAt: Date
    let connections: [ClashActiveConnection]
    let uploadSpeed: Double
    let downloadSpeed: Double
}

struct ClashConnectionHistorySample: Codable, Equatable, Identifiable, Sendable {
    let timestamp: Date
    let connectionAges: [TimeInterval]

    var id: Date { timestamp }
    var connectionCount: Int { connectionAges.count }
}

enum ClashConnectionPanelPhase: Equatable, Sendable {
    case idle
    case loading
    case ready
    case unavailable(String)
}

enum ClashOpenAIConnectionFilter {
    private static let observedDomains = ["openai.com", "chatgpt.com"]

    static func matches(_ connection: ClashConnectionRecord) -> Bool {
        let metadata = connection.metadata
        let candidates = [
            metadata.host,
            metadata.sniffHost,
            metadata.remoteDestination,
            connection.rulePayload,
        ]

        return candidates
            .compactMap { $0 }
            .contains(where: matchesObservedDomain)
    }

    static func displayHost(for connection: ClashConnectionRecord) -> String {
        let candidates = [
            connection.metadata.host,
            connection.metadata.sniffHost,
            connection.metadata.remoteDestination,
        ]

        for candidate in candidates.compactMap({ $0 }) {
            let normalized = normalizedHost(candidate)
            if !normalized.isEmpty {
                return normalized
            }
        }

        return connection.metadata.destinationIP ?? "—"
    }

    private static func matchesObservedDomain(_ rawValue: String) -> Bool {
        let host = normalizedHost(rawValue)
        return observedDomains.contains { domain in
            host == domain || host.hasSuffix(".\(domain)")
        }
    }

    private static func normalizedHost(_ rawValue: String) -> String {
        var value = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if let url = URL(string: value),
           let host = url.host {
            value = host
        }

        if value.hasPrefix("+.") {
            value.removeFirst(2)
        } else if value.hasPrefix(".") {
            value.removeFirst()
        }

        if let colon = value.lastIndex(of: ":"),
           !value.contains("]"),
           value[value.index(after: colon)...].allSatisfy(\.isNumber) {
            value = String(value[..<colon])
        }

        while value.hasSuffix(".") {
            value.removeLast()
        }
        return value
    }
}

struct ClashConnectionActivityCalculator {
    private struct Counter: Sendable {
        let upload: Int64
        let download: Int64
        let observedAt: Date
    }

    private var previousCounters: [String: Counter] = [:]

    mutating func reset() {
        previousCounters = [:]
    }

    mutating func update(
        response: ClashConnectionsResponse,
        observedAt: Date = Date()
    ) -> ClashConnectionActivitySnapshot {
        let matchingConnections = response.connections
            .filter(ClashOpenAIConnectionFilter.matches)

        var nextCounters: [String: Counter] = [:]
        var activeConnections: [ClashActiveConnection] = []
        activeConnections.reserveCapacity(matchingConnections.count)

        for connection in matchingConnections {
            let previous = previousCounters[connection.id]
            let elapsed = previous.map {
                max(0, observedAt.timeIntervalSince($0.observedAt))
            } ?? 0

            let uploadSpeed = speed(
                current: connection.upload,
                previous: previous?.upload,
                elapsed: elapsed)
            let downloadSpeed = speed(
                current: connection.download,
                previous: previous?.download,
                elapsed: elapsed)
            let startedAt = ClashConnectionDateParser.date(
                from: connection.start)

            activeConnections.append(
                ClashActiveConnection(
                    id: connection.id,
                    host: ClashOpenAIConnectionFilter.displayHost(
                        for: connection),
                    process: nonEmpty(connection.metadata.process),
                    network: nonEmpty(connection.metadata.network),
                    chains: connection.chains,
                    startedAt: startedAt,
                    duration: startedAt.map {
                        max(0, observedAt.timeIntervalSince($0))
                    } ?? 0,
                    uploadSpeed: uploadSpeed,
                    downloadSpeed: downloadSpeed))

            nextCounters[connection.id] = Counter(
                upload: connection.upload,
                download: connection.download,
                observedAt: observedAt)
        }

        previousCounters = nextCounters
        activeConnections.sort { lhs, rhs in
            if lhs.startedAt != rhs.startedAt {
                return (lhs.startedAt ?? .distantPast)
                    > (rhs.startedAt ?? .distantPast)
            }
            return lhs.host.localizedStandardCompare(rhs.host)
                == .orderedAscending
        }

        return ClashConnectionActivitySnapshot(
            observedAt: observedAt,
            connections: activeConnections,
            uploadSpeed: activeConnections.reduce(0) {
                $0 + $1.uploadSpeed
            },
            downloadSpeed: activeConnections.reduce(0) {
                $0 + $1.downloadSpeed
            })
    }

    private func speed(
        current: Int64,
        previous: Int64?,
        elapsed: TimeInterval
    ) -> Double {
        guard let previous,
              current >= previous,
              elapsed > 0 else {
            return 0
        }
        return Double(current - previous) / elapsed
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}

enum ClashConnectionDateParser {
    static func date(from value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

enum ClashConnectionHistory {
    static let sampleInterval: TimeInterval = 60
    static let retainedSampleCount = 60

    static func minuteStart(for date: Date) -> Date {
        Date(
            timeIntervalSince1970: floor(
                date.timeIntervalSince1970 / sampleInterval)
                * sampleInterval)
    }

    static func upserting(
        snapshot: ClashConnectionActivitySnapshot,
        into samples: [ClashConnectionHistorySample]
    ) -> [ClashConnectionHistorySample] {
        let timestamp = minuteStart(for: snapshot.observedAt)
        let sample = ClashConnectionHistorySample(
            timestamp: timestamp,
            connectionAges: snapshot.connections
                .map(\.duration)
                .sorted(by: >))

        var result = samples.filter { $0.timestamp != timestamp }
        result.append(sample)
        result.sort { $0.timestamp < $1.timestamp }

        let earliestTimestamp = timestamp.addingTimeInterval(
            -sampleInterval * Double(retainedSampleCount - 1))
        return result.filter { $0.timestamp >= earliestTimestamp }
    }

    static func pruned(
        _ samples: [ClashConnectionHistorySample],
        relativeTo date: Date = Date()
    ) -> [ClashConnectionHistorySample] {
        let latestTimestamp = minuteStart(for: date)
        let earliestTimestamp = latestTimestamp.addingTimeInterval(
            -sampleInterval * Double(retainedSampleCount - 1))

        return samples
            .filter {
                $0.timestamp >= earliestTimestamp
                    && $0.timestamp <= latestTimestamp
            }
            .sorted { $0.timestamp < $1.timestamp }
    }
}

enum ClashConnectionAgeScale {
    static let oldestColorAge: TimeInterval = 60 * 60

    static func progress(for age: TimeInterval) -> Double {
        min(max(age / oldestColorAge, 0), 1)
    }
}
