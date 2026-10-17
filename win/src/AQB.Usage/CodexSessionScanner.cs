using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AQB.Core;

namespace AQB.Usage;

/// <summary>Resolved default locations (CODEX_HOME / %APPDATA%\AIQuotaBar).</summary>
public static class UsagePaths
{
    public static string DefaultCodexHome =>
        Environment.GetEnvironmentVariable("CODEX_HOME") is { Length: > 0 } home
            ? home
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");

    public static string DefaultDataDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "AIQuotaBar");
}

internal static class UsageDigest
{
    public static string Digest(string value)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(value));
        return Convert.ToHexString(bytes).ToLowerInvariant();
    }
}

/// <summary>Per-file parse result: header fields plus billable records (macOS parser parity).</summary>
public sealed record ParsedUsageFile
{
    public string? SessionId { get; init; }

    public string? ParentId { get; init; }

    /// <summary>session_meta timestamp normalized to fixed ISO; used as the fork cutoff.</summary>
    public string? StartedAt { get; init; }

    public IReadOnlyList<UsageRecord> Records { get; init; } = Array.Empty<UsageRecord>();

    public int Issues { get; init; }

    public bool Incomplete { get; init; }
}

/// <summary>One parsed token_count line: the event plus resolution metadata.</summary>
public sealed record UsageRecord
{
    public required LocalUsageEvent Event { get; init; }

    /// <summary>The raw cumulative total snapshot (null for last-only lines).</summary>
    public UsageTokens? Cumulative { get; init; }

    public bool StartsBaseline { get; init; }
}

/// <summary>Parser state persisted between incremental scans of one file.</summary>
public sealed class ParserStateSnapshot
{
    public string Model { get; set; } = "unknown";

    public UsageTokens? PreviousTotal { get; set; }

    public Dictionary<string, string> Signatures { get; set; } = new();

    public string? PreviousSignature { get; set; }

    public Dictionary<string, int> Occurrences { get; set; } = new();

    public bool MetaSeen { get; set; }
}

/// <summary>Persisted incremental-scan entry for one rollout file (usage-scan-stamps.json).</summary>
public sealed class FileStampEntry
{
    /// <summary>"v2:{fileSize}:{mtimeSeconds}"; unchanged stamp means unchanged file.</summary>
    public string Stamp { get; set; } = "";

    /// <summary>Bytes already consumed (complete lines only; partial tails are retried).</summary>
    public long Length { get; set; }

    public string? Session { get; set; }

    public string? Parent { get; set; }

    public string? StartedAt { get; set; }

    public int Issues { get; set; }

    public bool Incomplete { get; set; }

    public List<UsageRecord> Records { get; set; } = new();

    public ParserStateSnapshot State { get; set; } = new();

    public ParsedUsageFile ToParsedFile() => new()
    {
        SessionId = Session,
        ParentId = Parent,
        StartedAt = StartedAt,
        Records = Records,
        Issues = Issues,
        Incomplete = Incomplete,
    };
}

/// <summary>Cross-file resolution outcome: billable events plus hold-back diagnostics.</summary>
public sealed record ResolveResult
{
    public required IReadOnlyList<LocalUsageEvent> Events { get; init; }

    /// <summary>Sessions held back because fork ancestry is missing; recounted when the parent appears.</summary>
    public int DeferredSessions { get; init; }

    public int Issues { get; init; }

    public required IReadOnlySet<string> DeferredSessionIds { get; init; }
}

/// <summary>Result of one incremental directory scan.</summary>
public sealed record ScanResult
{
    public required IReadOnlyList<LocalUsageEvent> Events { get; init; }

    public int DeferredSessions { get; init; }

    public int Issues { get; init; }

    public required IReadOnlySet<string> DeferredSessionIds { get; init; }

    /// <summary>Files whose stamp changed (or that are new) and were (re)parsed.</summary>
    public int FilesParsed { get; init; }

    /// <summary>Files skipped because size+mtime were unchanged.</summary>
    public int FilesSkipped { get; init; }

    public int FilesSeen { get; init; }
}

/// <summary>
/// Scans {codexHome}/sessions and {codexHome}/archived_sessions for Codex rollout
/// *.jsonl files and turns token_count lines into billable events. Incremental:
/// per-file stamps (size:mtime) persist to usage-scan-stamps.json and only the
/// grown tail of a file is parsed; a shrunken file is re-read from the start.
/// </summary>
public sealed class CodexSessionScanner
{
    public const string StampsFileName = "usage-scan-stamps.json";

    /// <summary>Retention window (days) shared with the service-level prune policy.</summary>
    public const int RecordRetentionDays = 40;

    private static readonly JsonSerializerOptions StampsJson = new(Json.SnakeCase)
    {
        WriteIndented = false,
    };

    public CodexSessionScanner(string? codexHome = null, string? stampsPath = null)
    {
        CodexHome = Path.GetFullPath(codexHome is { Length: > 0 } home ? home : UsagePaths.DefaultCodexHome);
        StampsPath = stampsPath is { Length: > 0 } stamps
            ? stamps
            : Path.Combine(UsagePaths.DefaultDataDir, StampsFileName);
    }

    public string CodexHome { get; }

    public string StampsPath { get; }

    /// <summary>Incremental scan: skips unchanged files, appends only grown tails, then resolves sessions.</summary>
    public ScanResult Scan()
    {
        var stamps = LoadStamps();
        var issues = 0;
        var parsed = 0;
        var skipped = 0;
        var seen = 0;
        var entries = new Dictionary<string, FileStampEntry>(OperatingSystem.IsWindows()
            ? StringComparer.OrdinalIgnoreCase
            : StringComparer.Ordinal);
        foreach (var (path, size, mtime) in EnumerateRolloutFiles(ref issues))
        {
            seen++;
            var stamp = $"v2:{size}:{mtime}";
            if (stamps.TryGetValue(path, out var previous) && previous.Stamp == stamp)
            {
                entries[path] = previous;
                skipped++;
                continue;
            }

            var entry = ParseEntry(path, size, previous);
            entry.Stamp = stamp;
            entries[path] = entry;
            parsed++;
        }

        var resolved = Resolve(entries.Values.Select(e => e.ToParsedFile()));
        SaveStamps(entries);
        return new ScanResult
        {
            Events = resolved.Events,
            DeferredSessions = resolved.DeferredSessions,
            Issues = resolved.Issues + issues,
            DeferredSessionIds = resolved.DeferredSessionIds,
            FilesParsed = parsed,
            FilesSkipped = skipped,
            FilesSeen = seen,
        };
    }

    /// <summary>Resolves parsed files into deduplicated billable events (fork prefix removal, deferral).</summary>
    public static ResolveResult Resolve(IEnumerable<ParsedUsageFile> files)
    {
        var groups = new Dictionary<string, List<ParsedUsageFile>>();
        foreach (var file in files)
        {
            if (string.IsNullOrEmpty(file.SessionId))
            {
                continue;
            }

            if (!groups.TryGetValue(file.SessionId!, out var parts))
            {
                groups[file.SessionId!] = parts = new List<ParsedUsageFile>();
            }

            parts.Add(file);
        }

        var memo = new Dictionary<string, List<UsageRecord>>();
        var unresolved = new HashSet<string>();

        List<UsageRecord>? RecordsOf(string id, HashSet<string> visiting)
        {
            if (memo.TryGetValue(id, out var cached))
            {
                return cached;
            }

            if (visiting.Contains(id) || !groups.TryGetValue(id, out var parts))
            {
                return null;
            }

            var inner = new HashSet<string>(visiting) { id };
            var all = new List<UsageRecord>();
            foreach (var part in parts)
            {
                var prefix = 0;
                UsageTokens? forkBaseline = null;
                if (part.ParentId is { } parentId)
                {
                    if (part.StartedAt is null || RecordsOf(parentId, inner) is null)
                    {
                        unresolved.Add(id);
                        return null;
                    }

                    // Match against the parent's raw timeline (including the parent's own
                    // inherited prefix) so grandparent history is not double counted.
                    var cutoff = part.StartedAt;
                    var seenParent = new HashSet<string>();
                    var inherited = new List<UsageRecord>();
                    if (groups.TryGetValue(parentId, out var parentParts))
                    {
                        foreach (var record in parentParts.SelectMany(p => p.Records))
                        {
                            if (seenParent.Add(record.Event.Id)
                                && string.CompareOrdinal(record.Event.OccurredAt, cutoff) <= 0)
                            {
                                inherited.Add(record);
                            }
                        }
                    }

                    inherited.Sort((a, b) => string.CompareOrdinal(a.Event.OccurredAt, b.Event.OccurredAt));
                    forkBaseline = inherited.Count > 0 ? inherited[^1].Cumulative : null;
                    var position = 0;
                    foreach (var record in part.Records)
                    {
                        if (string.CompareOrdinal(record.Event.OccurredAt, cutoff) > 0)
                        {
                            break;
                        }

                        var index = -1;
                        for (var i = position; i < inherited.Count; i++)
                        {
                            if (string.Equals(inherited[i].Event.Signature, record.Event.Signature, StringComparison.Ordinal))
                            {
                                index = i;
                                break;
                            }
                        }

                        if (index < 0)
                        {
                            break;
                        }

                        position = index + 1;
                        prefix++;
                    }
                }

                var own = part.Records.Skip(prefix).ToList();
                if (part.ParentId is not null && prefix == 0 && own.Count > 0
                    && own[0].StartsBaseline && own[0].Event.Quality == "cumulative-delta")
                {
                    // A fork with no copied prefix starts from a cumulative-only snapshot:
                    // subtract the parent's baseline instead of replaying it as fresh usage.
                    var first = own[0];
                    if (first.Cumulative is not { } total || forkBaseline is not { } prior
                        || !UsageTokens.MonotonicFrom(total, prior))
                    {
                        unresolved.Add(id);
                        return null;
                    }

                    var delta = UsageTokens.Delta(total, prior);
                    if (!delta.IsValid)
                    {
                        unresolved.Add(id);
                        return null;
                    }

                    own.RemoveAt(0);
                    if (delta.Total > 0)
                    {
                        own.Insert(0, first with { Event = first.Event with { Tokens = delta }, StartsBaseline = true });
                    }
                }

                all.AddRange(own);
            }

            var seenIds = new HashSet<string>();
            all = all.Where(r => seenIds.Add(r.Event.Id))
                .OrderBy(r => r.Event.OccurredAt, StringComparer.Ordinal)
                .ToList();

            // A continuation page may begin with a cumulative-only snapshot. Its first total
            // is not fresh consumption: subtract the previously seen baseline (never guess).
            UsageTokens? previous = null;
            var adjusted = new List<UsageRecord>(all.Count);
            foreach (var record in all)
            {
                var cumulative = record.Cumulative;
                try
                {
                    if (record.StartsBaseline && record.Event.Quality == "cumulative-delta"
                        && cumulative is { } total && previous is { } prior)
                    {
                        if (!UsageTokens.MonotonicFrom(total, prior))
                        {
                            unresolved.Add(id);
                            continue;
                        }

                        var delta = UsageTokens.Delta(total, prior);
                        if (delta.IsValid && delta.Total > 0)
                        {
                            adjusted.Add(record with
                            {
                                Event = record.Event with { Tokens = delta },
                                StartsBaseline = false,
                            });
                        }
                    }
                    else
                    {
                        adjusted.Add(record);
                    }
                }
                finally
                {
                    if (cumulative is not null)
                    {
                        previous = cumulative;
                    }
                }
            }

            memo[id] = adjusted;
            return adjusted;
        }

        var events = new List<LocalUsageEvent>();
        foreach (var id in groups.Keys.OrderBy(k => k, StringComparer.Ordinal))
        {
            if (RecordsOf(id, new HashSet<string>()) is { } records)
            {
                events.AddRange(records.Select(r => r.Event));
            }
        }

        var unique = new HashSet<string>();
        var ordered = events.Where(e => unique.Add(e.Id))
            .OrderBy(e => e.OccurredAt, StringComparer.Ordinal)
            .ThenBy(e => e.Id, StringComparer.Ordinal)
            .ToList();
        return new ResolveResult
        {
            Events = ordered,
            DeferredSessions = unresolved.Count,
            Issues = files.Sum(f => f.Issues),
            DeferredSessionIds = unresolved,
        };
    }

    /// <summary>Parses a full rollout file from disk (no incremental state).</summary>
    public static ParsedUsageFile ParseFile(string path) => ParseEntry(path, new FileInfo(path).Length, null).ToParsedFile();

    /// <summary>Parses pre-split lines (test convenience; each string is one JSONL line).</summary>
    public static ParsedUsageFile ParseLines(IEnumerable<string> lines)
    {
        var entry = new FileStampEntry();
        var parser = new RolloutParser(entry, new ParserStateSnapshot());
        foreach (var line in lines)
        {
            parser.ProcessLine(line);
        }

        return entry.ToParsedFile();
    }

    internal static FileStampEntry ParseEntry(string path, long size, FileStampEntry? previous)
    {
        if (previous is not null && size > previous.Length)
        {
            return ParseRange(path, previous.Length, previous);
        }

        return ParseRange(path, 0, null);
    }

    private static FileStampEntry ParseRange(string path, long offset, FileStampEntry? resume)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete);
        if (stream.Length < offset)
        {
            // The file shrank (truncate/replace): start over.
            offset = 0;
            resume = null;
        }
        else
        {
            stream.Seek(offset, SeekOrigin.Begin);
        }

        var entry = new FileStampEntry
        {
            Length = offset,
            Session = resume?.Session,
            Parent = resume?.Parent,
            StartedAt = resume?.StartedAt,
            Issues = resume?.Issues ?? 0,
            Records = resume is null ? new List<UsageRecord>() : new List<UsageRecord>(resume.Records),
        };
        var parser = new RolloutParser(entry, resume?.State ?? new ParserStateSnapshot());

        var pending = new MemoryStream();
        var buffer = new byte[65_536];
        long consumed = offset;
        int read;
        while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
        {
            consumed += read;
            var start = 0;
            for (var i = 0; i < read; i++)
            {
                if (buffer[i] != '\n')
                {
                    continue;
                }

                pending.Write(buffer, start, i - start);
                parser.ProcessLine(Encoding.UTF8.GetString(pending.GetBuffer(), 0, (int)pending.Length));
                pending.SetLength(0);
                start = i + 1;
            }

            pending.Write(buffer, start, read - start);
        }

        if (pending.Length > 0)
        {
            var tail = Encoding.UTF8.GetString(pending.GetBuffer(), 0, (int)pending.Length);
            if (LooksLikeCompleteLine(tail))
            {
                parser.ProcessLine(tail);
            }
            else
            {
                entry.Incomplete = true;
                consumed -= pending.Length;
            }
        }

        entry.Length = consumed;
        return entry;
    }

    private static bool LooksLikeCompleteLine(string tail)
    {
        if (tail.Length == 0 || (tail[0] != '{' && tail[0] != ' '))
        {
            return false;
        }

        try
        {
            JsonNode.Parse(tail);
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private IEnumerable<(string Path, long Size, long Mtime)> EnumerateRolloutFiles(ref int issues)
    {
        var files = new List<(string, long, long)>();
        foreach (var name in new[] { "sessions", "archived_sessions" })
        {
            var dir = Path.Combine(CodexHome, name);
            if (File.Exists(dir))
            {
                // Occupied by a regular file: count one issue like the macOS scanner.
                issues++;
                continue;
            }

            if (!Directory.Exists(dir))
            {
                continue;
            }

            try
            {
                foreach (var path in Directory.EnumerateFiles(dir, "*.jsonl", SearchOption.AllDirectories)
                             .OrderBy(p => p, StringComparer.Ordinal))
                {
                    FileInfo info;
                    try
                    {
                        info = new FileInfo(path);
                    }
                    catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                    {
                        issues++;
                        continue;
                    }

                    if (info.Exists && !IsHidden(info))
                    {
                        files.Add((info.FullName, info.Length,
                            new DateTimeOffset(info.LastWriteTimeUtc).ToUnixTimeSeconds()));
                    }
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                issues++;
            }
        }

        return files;
    }

    private static bool IsHidden(FileSystemInfo info)
        => info.Name.Length > 0 && info.Name[0] == '.'
           || (info.Attributes & FileAttributes.Hidden) != 0;

    private Dictionary<string, FileStampEntry> LoadStamps()
    {
        var node = Json.TryReadFile(StampsPath);
        if (node is null)
        {
            return new Dictionary<string, FileStampEntry>();
        }

        try
        {
            var loaded = node.Deserialize<Dictionary<string, FileStampEntry>>(StampsJson) ?? [];
            return new Dictionary<string, FileStampEntry>(loaded, OperatingSystem.IsWindows()
                ? StringComparer.OrdinalIgnoreCase
                : StringComparer.Ordinal);
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or NotSupportedException)
        {
            // Corrupt cache: fall back to a full re-scan.
            return new Dictionary<string, FileStampEntry>();
        }
    }

    private void SaveStamps(Dictionary<string, FileStampEntry> entries)
    {
        try
        {
            Json.AtomicWrite(StampsPath, JsonSerializer.Serialize(entries, StampsJson));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Best effort: the next scan re-parses.
        }
    }

    /// <summary>Loose line parser (macOS UsageParser parity, minus account attribution).</summary>
    private sealed class RolloutParser
    {
        private readonly FileStampEntry _result;
        private readonly ParserStateSnapshot _state;

        public RolloutParser(FileStampEntry result, ParserStateSnapshot state)
        {
            _result = result;
            _state = state;
        }

        public void ProcessLine(string line)
        {
            if (line.Length == 0)
            {
                return;
            }

            // Most rollout bytes are conversation/tool bodies; skip them cheaply.
            if (line[0] != '{' && line[0] != ' ')
            {
                _result.Issues++;
                return;
            }

            if (!line.Contains("\"session_meta\"", StringComparison.Ordinal)
                && !line.Contains("\"turn_context\"", StringComparison.Ordinal)
                && !line.Contains("\"token_count\"", StringComparison.Ordinal))
            {
                return;
            }

            JsonNode? node;
            try
            {
                node = JsonNode.Parse(line);
            }
            catch (JsonException)
            {
                _result.Issues++;
                return;
            }

            if (node is not JsonObject obj
                || obj["type"] is not JsonValue typeValue || !typeValue.TryGetValue<string>(out var type)
                || obj["payload"] is not JsonObject payload)
            {
                _result.Issues++;
                return;
            }

            if (type == "session_meta")
            {
                ProcessSessionMeta(obj, payload);
                return;
            }

            if (type == "turn_context")
            {
                var model = StringOf(Pick(payload, "model"));
                if (model is not null)
                {
                    _state.Model = model;
                }

                return;
            }

            if (type != "event_msg" || StringOf(payload["type"]) != "token_count"
                || payload["info"] is not JsonObject info)
            {
                return;
            }

            ProcessTokenCount(obj, payload, info);
        }

        private void ProcessSessionMeta(JsonObject obj, JsonObject payload)
        {
            if (_state.MetaSeen)
            {
                return;
            }

            _state.MetaSeen = true;
            var session = StringOf(Pick(payload, "id", "thread_id", "threadId"));
            _result.StartedAt = StringOf(obj["timestamp"]) is { } raw
                && TimeText.TryParseIso(raw, out var started)
                ? TimeText.FixedIso(started)
                : null;
            var spawn = (payload["source"] as JsonObject)?["subagent"] as JsonObject;
            var spawned = StringOf((spawn?["thread_spawn"] as JsonObject)?["parent_thread_id"]);
            var forked = StringOf(payload["forked_from_id"]);
            if (forked is not null && spawned is not null && forked != spawned)
            {
                _result.Issues++;
                session = null;
            }

            var parent = forked ?? spawned;
            if (parent is not null && parent == session)
            {
                _result.Issues++;
                session = null;
            }

            _result.Session = session;
            _result.Parent = parent;
        }

        private void ProcessTokenCount(JsonObject obj, JsonObject payload, JsonObject info)
        {
            var model = StringOf(Pick(info, "model", "model_name")) ?? StringOf(payload["model"]);
            if (model is not null)
            {
                _state.Model = model;
            }

            var total = CountTokens(info["total_token_usage"]);
            var last = CountTokens(info["last_token_usage"]);
            if ((info["last_token_usage"] is JsonObject && last is null)
                || (info["total_token_usage"] is JsonObject && total is null))
            {
                _result.Issues++;
                return;
            }

            if (total is null && last is null)
            {
                _result.Issues++;
                return;
            }

            var signature = $"{total?.SignatureText ?? "-"}/{last?.SignatureText ?? "-"}";
            var source = StringOf(payload?["rate_limits"]?["limit_id"]) ?? "default";
            var duplicate = total is not null
                && (_state.Signatures.TryGetValue(source, out var seen) && seen == signature
                    || _state.PreviousSignature == signature);
            if (total is not null)
            {
                _state.Signatures[source] = signature;
            }

            _state.PreviousSignature = signature;
            var startsBaseline = _state.PreviousTotal is null;
            UsageTokens? tokens = null;
            var quality = "exact";
            if (last is { } exact)
            {
                tokens = exact;
            }
            else if (total is { } cumulative)
            {
                quality = "cumulative-delta";
                if (_state.PreviousTotal is { } previous)
                {
                    // A counter reset is ambiguous without last_token_usage: skip the segment.
                    if (!UsageTokens.MonotonicFrom(cumulative, previous))
                    {
                        _result.Issues++;
                    }
                    else
                    {
                        tokens = UsageTokens.Delta(cumulative, previous);
                    }
                }
                else
                {
                    tokens = cumulative;
                }
            }

            if (total is not null)
            {
                _state.PreviousTotal = total;
            }

            if (duplicate || tokens is null || tokens.Value.Total <= 0)
            {
                return;
            }

            if (!tokens.Value.IsValid || string.IsNullOrEmpty(_result.Session)
                || StringOf(obj["timestamp"]) is not { } rawTime
                || !TimeText.TryParseIso(rawTime, out var time))
            {
                _result.Issues++;
                return;
            }

            var timestamp = TimeText.FixedIso(time);
            var @base = $"{_result.Session}|{timestamp}|{signature}";
            _state.Occurrences.TryGetValue(@base, out var occurrence);
            _state.Occurrences[@base] = occurrence + 1;
            var normalized = _state.Model.Trim().ToLowerInvariant();
            _result.Records.Add(new UsageRecord
            {
                Event = new LocalUsageEvent
                {
                    Id = UsageDigest.Digest($"{@base}|{occurrence}"),
                    OccurredAt = timestamp,
                    Model = normalized.Length == 0 ? "unknown" : normalized,
                    Tokens = tokens.Value,
                    Quality = quality,
                    LimitId = source,
                    Signature = signature,
                },
                Cumulative = total,
                StartsBaseline = startsBaseline,
            });
        }

        private static JsonNode? Pick(JsonObject obj, params string[] keys)
        {
            foreach (var key in keys)
            {
                if (obj.ContainsKey(key))
                {
                    return obj[key];
                }
            }

            return null;
        }

        private static string? StringOf(JsonNode? node)
            => node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

        /// <summary>
        /// Validates one counters object: requires input_tokens and output_tokens; every value
        /// must be a non-boolean finite integral number in [0, 1e12]; otherwise the whole
        /// object is rejected (never falls back to inflated totals).
        /// </summary>
        private static UsageTokens? CountTokens(JsonNode? node)
        {
            if (node is not JsonObject obj
                || !obj.ContainsKey("input_tokens") || !obj.ContainsKey("output_tokens"))
            {
                return null;
            }

            if (!TryNumber(obj["input_tokens"], out var input)
                || !TryNumber(obj["cached_input_tokens"], out var cached)
                || !TryNumber(obj["cache_write_input_tokens"], out var cacheWrite)
                || !TryNumber(obj["output_tokens"], out var output)
                || !TryNumber(obj["reasoning_output_tokens"], out var reasoning))
            {
                return null;
            }

            var tokens = new UsageTokens(input, cached, cacheWrite, output, reasoning);
            return tokens.IsValid ? tokens : null;
        }

        private static bool TryNumber(JsonNode? node, out long value)
        {
            value = 0;
            if (node is null)
            {
                return true;
            }

            if (node is JsonValue json && json.TryGetValue<double>(out var number)
                && !double.IsNaN(number) && !double.IsInfinity(number)
                && Math.Round(number) == number && number >= 0 && number <= UsageTokens.MaxValue)
            {
                value = (long)number;
                return true;
            }

            return false;
        }
    }
}
