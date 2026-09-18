import Foundation
import CryptoKit

public enum UsageFailure: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

public func usageDigest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

public enum UsageTime {
    // ISO8601DateFormatter is mutable; serialize access to shared formatter instances.
    private static let lock = NSLock()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let plain = ISO8601DateFormatter()
    public static func parse(_ string: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return fractional.date(from: string) ?? plain.date(from: string)
    }
    public static func string(_ date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return fractional.string(from: date)
    }
}

public struct UsageTokens: Codable, Equatable, Sendable {
    public var input: Int64
    public var cached: Int64
    public var cacheWrite: Int64
    public var output: Int64
    public var reasoning: Int64
    public var total: Int64 { input + output }
    public init(input: Int64 = 0, cached: Int64 = 0, cacheWrite: Int64 = 0, output: Int64 = 0, reasoning: Int64 = 0) {
        self.input = input; self.cached = cached; self.cacheWrite = cacheWrite
        self.output = output; self.reasoning = reasoning
    }
    public var valid: Bool {
        [input, cached, cacheWrite, output, reasoning].allSatisfy { $0 >= 0 && $0 <= 1_000_000_000_000 }
            && cached + cacheWrite <= input && reasoning <= output
    }
    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(input: lhs.input + rhs.input, cached: lhs.cached + rhs.cached,
             cacheWrite: lhs.cacheWrite + rhs.cacheWrite, output: lhs.output + rhs.output,
             reasoning: lhs.reasoning + rhs.reasoning)
    }
    var signature: String { "\(input):\(cached):\(cacheWrite):\(output):\(reasoning)" }
}

public struct LocalUsageEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let occurredAt: String
    public let model: String
    public let tokens: UsageTokens
    public let quality: String
    public let parserVersion: Int
    public let accountID: String?
    public let accountSource: String?
    public init(id: String, occurredAt: String, model: String, tokens: UsageTokens, quality: String = "exact", parserVersion: Int = 1, accountID: String? = nil, accountSource: String? = nil) {
        self.id = id; self.occurredAt = occurredAt; self.model = model
        self.tokens = tokens; self.quality = quality; self.parserVersion = parserVersion
        self.accountID = accountID; self.accountSource = accountSource
    }
}

/// USD per million tokens. No fuzzy model matching or implicit zero-price fallback.
public struct UsagePrice: Codable, Sendable {
    public var model: String
    public var version: String
    public var source: String
    public var effectiveFrom: String
    public var effectiveTo: String?
    public var input: Decimal
    public var cached: Decimal
    public var cacheWrite: Decimal?
    public var output: Decimal
    public init(model: String, version: String, source: String, effectiveFrom: String, effectiveTo: String? = nil,
                input: Decimal, cached: Decimal, cacheWrite: Decimal? = nil, output: Decimal) {
        self.model = model; self.version = version; self.source = source
        self.effectiveFrom = effectiveFrom; self.effectiveTo = effectiveTo
        self.input = input; self.cached = cached; self.cacheWrite = cacheWrite; self.output = output
    }
    public func cost(_ event: LocalUsageEvent) -> Decimal? {
        guard event.tokens.valid, model == event.model, let start = UsageTime.parse(effectiveFrom),
              let time = UsageTime.parse(event.occurredAt), time >= start,
              effectiveTo == nil || time < (UsageTime.parse(effectiveTo!) ?? .distantPast),
              event.tokens.cacheWrite == 0 || cacheWrite != nil else { return nil }
        return amount(event.tokens)
    }
    fileprivate func amount(_ t: UsageTokens) -> Decimal {
        return (Decimal(t.input - t.cached - t.cacheWrite) * input + Decimal(t.cached) * cached
            + Decimal(t.cacheWrite) * (cacheWrite ?? 0) + Decimal(t.output) * output) / 1_000_000
    }
    public static func validate(_ prices: [Self]) throws {
        for price in prices {
            guard !price.model.isEmpty, !price.version.isEmpty, !price.source.isEmpty,
                  let from = UsageTime.parse(price.effectiveFrom),
                  price.effectiveTo == nil || (UsageTime.parse(price.effectiveTo!) ?? .distantPast) > from,
                  [price.input, price.cached, price.output, price.cacheWrite ?? 0].allSatisfy({ !$0.isNaN && $0 >= 0 && $0 <= 1_000_000 }) else {
                throw UsageFailure.invalid("Invalid model price or effective date")
            }
        }
        for (i, a) in prices.enumerated() {
            for b in prices.dropFirst(i + 1) where a.model == b.model {
                if UsageTime.parse(a.effectiveFrom)! < (b.effectiveTo.flatMap(UsageTime.parse) ?? .distantFuture)
                    && UsageTime.parse(b.effectiveFrom)! < (a.effectiveTo.flatMap(UsageTime.parse) ?? .distantFuture) {
                    throw UsageFailure.invalid("Overlapping prices for \(a.model)")
                }
            }
        }
    }
}

public struct UsageSummary: Sendable {
    public var records = 0
    public var estimatedRecords = 0
    public var tokens = UsageTokens()
    public var pricedRecords = 0
    public var cost: Decimal = 0
    public var byModel: [String: Int64] = [:]
    public var cacheHitRate: Double? { tokens.input > 0 ? Double(tokens.cached) / Double(tokens.input) : nil }
    public init(events: [LocalUsageEvent] = [], prices: [UsagePrice] = [], from: Date = .distantPast, to: Date = .distantFuture) {
        let lower = UsageTime.string(from), upper = UsageTime.string(to)
        // Parse price dates once and aggregate before Decimal arithmetic. A large
        // history must not run hundreds of thousands of date parsers on the UI actor.
        var rates: [String: [(index: Int, from: String, to: String)]] = [:]
        for (index, price) in prices.enumerated() {
            guard let start = UsageTime.parse(price.effectiveFrom) else { continue }
            rates[price.model, default: []].append((index, UsageTime.string(start),
                price.effectiveTo.flatMap(UsageTime.parse).map(UsageTime.string) ?? UsageTime.string(.distantFuture)))
        }
        var pricedTokens: [Int: UsageTokens] = [:]
        for e in events {
            guard e.occurredAt >= lower, e.occurredAt < upper else { continue }
            records += 1; tokens = tokens + e.tokens
            if e.quality != "exact" { estimatedRecords += 1 }
            byModel[e.model, default: 0] += e.tokens.total
            if let rate = rates[e.model]?.first(where: { e.occurredAt >= $0.from && e.occurredAt < $0.to }),
               e.tokens.cacheWrite == 0 || prices[rate.index].cacheWrite != nil {
                pricedTokens[rate.index] = (pricedTokens[rate.index] ?? UsageTokens()) + e.tokens
                pricedRecords += 1
            }
        }
        for (index, tokens) in pricedTokens { cost += prices[index].amount(tokens) }
    }
}
