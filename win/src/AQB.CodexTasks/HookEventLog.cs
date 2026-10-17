using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AQB.Core;

namespace AQB.CodexTasks;

/// <summary>A single normalized hook event persisted to the JSONL log.</summary>
public sealed class HookEvent
{
    public const string TurnStarted = "turn.started";
    public const string TurnStopped = "turn.stopped";
    public const string SessionEnd = "session.end";

    /// <summary>turn.started | turn.stopped | session.end.</summary>
    public string Type { get; set; } = "";

    public string SessionId { get; set; } = "";

    public string? TurnId { get; set; }

    /// <summary>Fixed-millisecond ISO-8601 UTC (TimeText.FixedIso).</summary>
    public string At { get; set; } = "";

    public string Provider { get; set; } = "codex";

    public JsonObject ToJson()
    {
        var node = new JsonObject
        {
            ["type"] = Type,
            ["sessionId"] = SessionId,
        };
        if (!string.IsNullOrEmpty(TurnId))
        {
            node["turnId"] = TurnId;
        }

        node["at"] = At;
        node["provider"] = Provider;
        return node;
    }
}

/// <summary>
/// Append-only JSONL event log shared between the stateless hook process
/// (AQB.Hook) and the bar app: %LOCALAPPDATA%\AIQuotaBar\task-events.jsonl.
/// Replaces the macOS DistributedNotificationCenter bridge (codex.md §4.2/§6).
/// Reads tolerate corrupt lines; the file is compacted when it grows too large.
/// </summary>
public sealed class HookEventLog
{
    public const long CompactionThresholdBytes = 4 * 1024 * 1024;
    public const int CompactionKeepEvents = 1000;

    private readonly object _gate = new();

    public HookEventLog(string? path = null)
    {
        Path = path ?? DefaultPath;
    }

    public static string DefaultPath => System.IO.Path.Combine(CodexPaths.AppDataDirectory(), "task-events.jsonl");

    public string Path { get; }

    /// <summary>Appends one event as a single line (atomic per-line append).</summary>
    public void Append(HookEvent evt)
    {
        lock (_gate)
        {
            CompactIfNeeded();
            var directory = System.IO.Path.GetDirectoryName(Path);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }

            var line = evt.ToJson().ToJsonString(Json.CamlCaseWrite) + "\n";
            // FileMode.Append with FileShare.Read keeps a single OS-level append.
            using var stream = new FileStream(Path, FileMode.Append, FileAccess.Write, FileShare.Read);
            var bytes = Encoding.UTF8.GetBytes(line);
            stream.Write(bytes, 0, bytes.Length);
            stream.Flush();
        }
    }

    /// <summary>Reads every valid event; corrupt or partial lines are skipped.</summary>
    public List<HookEvent> ReadAll()
    {
        lock (_gate)
        {
            var events = new List<HookEvent>();
            try
            {
                if (!File.Exists(Path))
                {
                    return events;
                }

                foreach (var line in File.ReadLines(Path))
                {
                    if (TryParseLine(line) is { } evt)
                    {
                        events.Add(evt);
                    }
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // Unreadable log behaves like an empty one.
            }

            return events;
        }
    }

    public void Clear()
    {
        lock (_gate)
        {
            try
            {
                if (File.Exists(Path))
                {
                    File.Delete(Path);
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
            }
        }
    }

    public static HookEvent? TryParseLine(string? line)
    {
        if (string.IsNullOrWhiteSpace(line))
        {
            return null;
        }

        try
        {
            var node = JsonNode.Parse(line);
            if (node is null)
            {
                return null;
            }

            var type = node.GetString("type");
            var sessionId = node.GetString("sessionId");
            if (type.Length == 0 || sessionId.Length == 0)
            {
                return null;
            }

            var turnId = node.GetString("turnId");
            var provider = node.GetString("provider");
            return new HookEvent
            {
                Type = type,
                SessionId = sessionId,
                TurnId = turnId.Length == 0 ? null : turnId,
                At = node.GetString("at"),
                Provider = provider.Length == 0 ? "codex" : provider,
            };
        }
        catch (Exception e) when (e is JsonException or FormatException)
        {
            return null;
        }
    }

    private void CompactIfNeeded()
    {
        try
        {
            var info = new FileInfo(Path);
            if (!info.Exists || info.Length <= CompactionThresholdBytes)
            {
                return;
            }

            var all = ReadAllUnlocked();
            var kept = all.Count > CompactionKeepEvents ? all[^CompactionKeepEvents..] : all;
            var builder = new StringBuilder();
            foreach (var evt in kept)
            {
                builder.Append(evt.ToJson().ToJsonString(Json.CamlCaseWrite)).Append('\n');
            }

            Json.AtomicWrite(Path, builder.ToString());
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Compaction is best-effort; a failed compaction must not block appends.
        }
    }

    private List<HookEvent> ReadAllUnlocked()
    {
        var events = new List<HookEvent>();
        foreach (var line in File.ReadLines(Path))
        {
            if (TryParseLine(line) is { } evt)
            {
                events.Add(evt);
            }
        }

        return events;
    }
}
