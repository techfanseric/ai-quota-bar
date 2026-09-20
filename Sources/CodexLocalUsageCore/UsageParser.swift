import Foundation

public struct ParsedUsageFile: Codable, Equatable, Sendable {
    public var sessionID: String?
    public var parentID: String?
    public var startedAt: Date?
    public var records: [Record] = []
    public var issues = 0
    public var incomplete = false
    public struct Record: Codable, Equatable, Sendable {
        public let event: LocalUsageEvent
        public let signature: String
        let cumulative: UsageTokens?
        let startsBaseline: Bool
    }
}

public enum UsageParser {
    /// Only these fields leave the parser. Message content is never persisted.
    public static func parse(url: URL) throws -> ParsedUsageFile {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var parser = State()
        var pending = Data()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            var start = chunk.startIndex
            while let end = chunk[start...].firstIndex(of: 10) {
                pending.append(chunk[start..<end])
                parser.line(pending)
                pending.removeAll(keepingCapacity: false)
                start = end + 1
            }
            pending.append(chunk[start...])
        }
        if !pending.isEmpty {
            if (try? JSONSerialization.jsonObject(with: pending)) != nil { parser.line(pending) }
            else { parser.result.incomplete = true }
        }
        return parser.result
    }

    public static func parse(lines: [String]) -> ParsedUsageFile {
        var parser = State()
        for line in lines { parser.line(Data(line.utf8)) }
        return parser.result
    }

    private struct State {
        var result = ParsedUsageFile()
        var model = "unknown"
        var turnAccountID: String?
        var previousTotal: UsageTokens?
        var signatures: [String: String] = [:]
        var previousSignature: String?
        var occurrences: [String: Int] = [:]
        var metaSeen = false

        mutating func line(_ data: Data) {
            guard !data.isEmpty else { return }
            // Most rollout bytes are conversation/tool bodies. Avoid JSON-decoding them.
            guard data.first == 123 || data.first == 32 else { result.issues += 1; return }
            if data.range(of: Data("\"session_meta\"".utf8)) == nil
                && data.range(of: Data("\"turn_context\"".utf8)) == nil
                && data.range(of: Data("\"token_count\"".utf8)) == nil { return }
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = obj["type"] as? String, let p = obj["payload"] as? [String: Any] else {
                result.issues += 1; return
            }
            if type == "session_meta", !metaSeen {
                metaSeen = true
                result.sessionID = (p["id"] ?? p["thread_id"] ?? p["threadId"]) as? String
                result.startedAt = (obj["timestamp"] as? String).flatMap(UsageTime.parse)
                let source = p["source"] as? [String: Any]
                let subagent = source?["subagent"] as? [String: Any]
                let spawned = (subagent?["thread_spawn"] as? [String: Any])?["parent_thread_id"] as? String
                let forked = p["forked_from_id"] as? String
                if let forked, let spawned, forked != spawned { result.issues += 1; result.sessionID = nil }
                result.parentID = forked ?? spawned
                if result.parentID == result.sessionID { result.issues += 1; result.sessionID = nil }
                return
            }
            if type == "turn_context" {
                turnAccountID = (p["chatgpt_account_id"] ?? p["account_id"]) as? String
                if let value = p["model"] as? String { model = value }
                return
            }
            guard type == "event_msg", p["type"] as? String == "token_count",
                  let info = p["info"] as? [String: Any] else { return }
            if let value = (info["model"] ?? info["model_name"] ?? p["model"]) as? String { model = value }
            let total = counters(info["total_token_usage"])
            let last = counters(info["last_token_usage"])
            if (info["last_token_usage"] is [String: Any] && last == nil)
                || (info["total_token_usage"] is [String: Any] && total == nil) { result.issues += 1; return }
            guard total != nil || last != nil else { result.issues += 1; return }
            let signature = "\(total?.signature ?? "-")/\(last?.signature ?? "-")"
            let source = ((p["rate_limits"] as? [String: Any])?["limit_id"] as? String) ?? "default"
            let duplicate = total != nil && (signatures[source] == signature || previousSignature == signature)
            if total != nil { signatures[source] = signature }
            previousSignature = signature
            let startsBaseline = previousTotal == nil
            var tokens: UsageTokens?
            var quality = "exact"
            if let last { tokens = last }
            else if let total {
                quality = "cumulative-delta"
                if let prev = previousTotal {
                    // A reset is ambiguous without last_token_usage. Establish a new baseline,
                    // retain a visible diagnostic, and resume with the next monotonic snapshot.
                    if total.input < prev.input || total.output < prev.output || total.cached < prev.cached
                        || total.cacheWrite < prev.cacheWrite || total.reasoning < prev.reasoning {
                        result.issues += 1
                    } else {
                        tokens = UsageTokens(input: total.input - prev.input, cached: total.cached - prev.cached,
                            cacheWrite: total.cacheWrite - prev.cacheWrite, output: total.output - prev.output,
                            reasoning: total.reasoning - prev.reasoning)
                    }
                } else { tokens = total }
            }
            if let total { previousTotal = total }
            guard !duplicate, let tokens, tokens.total > 0 else { return }
            guard tokens.valid, let session = result.sessionID, !session.isEmpty,
                  let rawTime = obj["timestamp"] as? String, let time = UsageTime.parse(rawTime) else {
                result.issues += 1; return
            }
            let timestamp = UsageTime.string(time)
            let base = "\(session)|\(timestamp)|\(signature)"
            let occurrence = occurrences[base, default: 0]
            occurrences[base] = occurrence + 1
            let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rawAccount = ((info["chatgpt_account_id"] ?? p["chatgpt_account_id"]) as? String) ?? turnAccountID
            let account = rawAccount.flatMap { $0.isEmpty ? nil : usageDigest("codex-account|" + $0) }
            let event = LocalUsageEvent(id: usageDigest("\(base)|\(occurrence)"), occurredAt: timestamp,
                model: normalizedModel.isEmpty ? "unknown" : normalizedModel, tokens: tokens, quality: quality, accountID: account, accountSource: account == nil ? nil : "log")
            result.records.append(.init(event: event, signature: signature, cumulative: total, startsBaseline: startsBaseline))
        }

        func counters(_ value: Any?) -> UsageTokens? {
            guard let d = value as? [String: Any], d["input_tokens"] != nil, d["output_tokens"] != nil else { return nil }
            func n(_ key: String) -> Int64? {
                guard let v = d[key] else { return 0 }
                guard let num = v as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID(),
                      num.doubleValue.isFinite, num.doubleValue.rounded() == num.doubleValue,
                      num.doubleValue >= 0, num.doubleValue <= 1_000_000_000_000 else { return nil }
                return num.int64Value
            }
            guard let i = n("input_tokens"), let c = n("cached_input_tokens"), let w = n("cache_write_input_tokens"),
                  let o = n("output_tokens"), let r = n("reasoning_output_tokens") else { return nil }
            let t = UsageTokens(input: i, cached: c, cacheWrite: w, output: o, reasoning: r)
            return t.valid ? t : nil
        }
    }

    /// Excludes a child's copied parent prefix; unresolved ancestry is held back, never guessed.
    public static func resolve(_ files: [ParsedUsageFile]) -> (events: [LocalUsageEvent], deferred: Int, issues: Int, deferredSessionIDs: Set<String>) {
        let groups = Dictionary(grouping: files.filter { $0.sessionID != nil }, by: { $0.sessionID! })
        var memo: [String: [ParsedUsageFile.Record]] = [:]
        var unresolved = Set<String>()
        func records(_ id: String, visiting: Set<String>) -> [ParsedUsageFile.Record]? {
            if let cached = memo[id] { return cached }
            guard !visiting.contains(id), let parts = groups[id] else { return nil }
            var all: [ParsedUsageFile.Record] = []
            for part in parts {
                var prefix = 0
                var forkBaseline: UsageTokens?
                if let parentID = part.parentID {
                    guard let start = part.startedAt, let _ = records(parentID, visiting: visiting.union([id])) else {
                        unresolved.insert(id); return nil
                    }
                    // Match against the parent's raw timeline, including its inherited prefix.
                    // Using only billable parent records would double count grandparent history.
                    let cutoff = UsageTime.string(start)
                    var seenParent = Set<String>()
                    let inherited = (groups[parentID] ?? []).flatMap(\.records)
                        .filter { seenParent.insert($0.event.id).inserted && $0.event.occurredAt <= cutoff }
                        .sorted { $0.event.occurredAt < $1.event.occurredAt }
                    forkBaseline = inherited.last?.cumulative
                    var position = 0
                    for record in part.records {
                        guard record.event.occurredAt <= cutoff else { break }
                        guard let index = inherited[position...].firstIndex(where: { $0.signature == record.signature }) else { break }
                        position = index + 1; prefix += 1
                    }
                }
                var own = Array(part.records.dropFirst(prefix))
                if part.parentID != nil, prefix == 0, let first = own.first,
                   first.startsBaseline, first.event.quality == "cumulative-delta" {
                    guard let total = first.cumulative, let prior = forkBaseline,
                          total.input >= prior.input, total.cached >= prior.cached,
                          total.cacheWrite >= prior.cacheWrite, total.output >= prior.output,
                          total.reasoning >= prior.reasoning else { unresolved.insert(id); return nil }
                    let delta = UsageTokens(input: total.input-prior.input, cached: total.cached-prior.cached,
                        cacheWrite: total.cacheWrite-prior.cacheWrite, output: total.output-prior.output,
                        reasoning: total.reasoning-prior.reasoning)
                    guard delta.valid else { unresolved.insert(id); return nil }
                    own.removeFirst()
                    if delta.total > 0 {
                        let e = first.event
                        own.insert(.init(event: LocalUsageEvent(id: e.id, occurredAt: e.occurredAt, model: e.model,
                            tokens: delta, quality: e.quality, accountID: e.accountID, accountSource: e.accountSource), signature: first.signature, cumulative: total, startsBaseline: true), at: 0)
                    }
                }
                all += own
            }
            var seen = Set<String>()
            all = all.filter { seen.insert($0.event.id).inserted }.sorted { $0.event.occurredAt < $1.event.occurredAt }
            // A continuation page may begin with a cumulative-only snapshot. Its first
            // total is not fresh consumption: subtract the prior page's baseline.
            var previous: UsageTokens?
            var adjusted: [ParsedUsageFile.Record] = []
            for record in all {
                defer { if let total = record.cumulative { previous = total } }
                if record.startsBaseline, record.event.quality == "cumulative-delta", let total = record.cumulative, let prior = previous {
                    guard total.input >= prior.input, total.cached >= prior.cached,
                          total.cacheWrite >= prior.cacheWrite, total.output >= prior.output,
                          total.reasoning >= prior.reasoning else { unresolved.insert(id); continue }
                    let delta = UsageTokens(input: total.input-prior.input, cached: total.cached-prior.cached,
                        cacheWrite: total.cacheWrite-prior.cacheWrite, output: total.output-prior.output,
                        reasoning: total.reasoning-prior.reasoning)
                    guard delta.valid, delta.total > 0 else { continue }
                    let e = record.event
                    adjusted.append(.init(event: LocalUsageEvent(id: e.id, occurredAt: e.occurredAt, model: e.model,
                        tokens: delta, quality: e.quality, accountID: e.accountID, accountSource: e.accountSource), signature: record.signature, cumulative: total, startsBaseline: false))
                } else { adjusted.append(record) }
            }
            memo[id] = adjusted
            return adjusted
        }
        var events: [LocalUsageEvent] = []
        for id in groups.keys.sorted() { events += (records(id, visiting: []) ?? []).map(\.event) }
        var seen = Set<String>()
        return (events.filter { seen.insert($0.id).inserted }, unresolved.count, files.reduce(0) { $0 + $1.issues }, unresolved)
    }
}

import CoreFoundation
