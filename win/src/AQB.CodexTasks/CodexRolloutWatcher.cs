using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AQB.Core;

namespace AQB.CodexTasks;

/// <summary>
/// Watches ~/.codex/sessions/**/*.jsonl rollout files with incremental tail parsing
/// (per-file length+mtime stamps persisted to %LOCALAPPDATA%\AIQuotaBar\rollout-stamps.json;
/// a file that shrinks is re-read from the start) and answers one question:
/// "does this session have a turn in flight?".
///
/// Best-effort port of the macOS CodexLocalActivityDetector (codex.md §4.3). The
/// state_5.sqlite candidate query, per-thread ownership validation, compaction
/// semantics and progress-line extraction are not ported; turn detection accepts
/// both the documented rollout shapes:
///   - top-level type "turn.started" / "turn.completed" / "turn.aborted";
///   - {type:"event_msg", payload:{type:"task_started"|"task_complete"|"turn_aborted"|
///     "task_aborted"|"token_count"}} lines, where turn_id defaults to "legacy"
///     (a legacy completion clears every turn of the file, as on macOS);
///   - heuristic: token_count lines with no known running turn imply an implicit
///     running turn (older CLI versions emit no explicit task_started lines).
/// </summary>
public sealed class CodexRolloutWatcher
{
    public const long BootstrapTailBytes = 16 * 1024 * 1024;
    public const long MaxReadPerPollBytes = 16 * 1024 * 1024;
    public const string LegacyTurnId = "legacy";
    public const string ImplicitTurnId = "implicit";

    private sealed class TurnState
    {
        public string TurnId = "";
        public DateTimeOffset? StartedAtUtc;
        public DateTimeOffset LastActivityUtc;
    }

    private sealed class FileState
    {
        public long Offset;
        public byte[] Partial = Array.Empty<byte>();
        public string SessionId = "";
        public readonly Dictionary<string, TurnState> Turns = new(StringComparer.Ordinal);
        public long LastLength;
        public long LastMtimeTicks;
        public bool Seeded;
    }

    private readonly object _gate = new();
    private readonly string _sessionsDirectory;
    private readonly string _stampsPath;
    private readonly Dictionary<string, FileState> _states = new(StringComparer.OrdinalIgnoreCase);
    private IReadOnlyList<CodexTaskInfo> _activeTasks = Array.Empty<CodexTaskInfo>();
    private bool _stampsDirty;

    public CodexRolloutWatcher(string? codexHome = null, string? stampsPath = null)
    {
        var home = codexHome ?? CodexPaths.DefaultHome();
        _sessionsDirectory = Path.Combine(home, "sessions");
        _stampsPath = stampsPath ?? DefaultStampsPath;
        LoadStamps();
    }

    public static string DefaultStampsPath => Path.Combine(CodexPaths.AppDataDirectory(), "rollout-stamps.json");

    public string SessionsDirectory => _sessionsDirectory;

    public string StampsPath => _stampsPath;

    /// <summary>Sessions with at least one turn believed to be running (Source = Local).</summary>
    public IReadOnlyList<CodexTaskInfo> ActiveTasks
    {
        get
        {
            lock (_gate)
            {
                return _activeTasks;
            }
        }
    }

    /// <summary>Scans the sessions tree once and refreshes <see cref="ActiveTasks"/>.</summary>
    public void Poll()
    {
        lock (_gate)
        {
            var paths = EnumerateRolloutFiles();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var path in paths)
            {
                seen.Add(path);
                try
                {
                    ProcessFile(path);
                }
                catch (Exception e) when (
                    e is IOException or UnauthorizedAccessException or FileNotFoundException)
                {
                    // Transient contention with the Codex CLI writer; retry next poll.
                }
            }

            foreach (var vanished in _states.Keys.Where(key => !seen.Contains(key)).ToList())
            {
                _states.Remove(vanished);
                _stampsDirty = true;
            }

            PersistStamps();
            _activeTasks = BuildActiveTasks();
        }
    }

    /// <summary>Forgets all in-memory state and deletes the stamps file (tests).</summary>
    public void Reset()
    {
        lock (_gate)
        {
            _states.Clear();
            _activeTasks = Array.Empty<CodexTaskInfo>();
            _stampsDirty = false;
            try
            {
                if (File.Exists(_stampsPath))
                {
                    File.Delete(_stampsPath);
                }
            }
            catch (IOException)
            {
            }
        }
    }

    private IEnumerable<string> EnumerateRolloutFiles()
    {
        try
        {
            return Directory
                .EnumerateFiles(_sessionsDirectory, "*.jsonl", SearchOption.AllDirectories)
                .ToList();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or DirectoryNotFoundException)
        {
            return Array.Empty<string>();
        }
    }

    private void ProcessFile(string path)
    {
        var info = new FileInfo(path);
        var length = info.Length;
        var mtime = info.LastWriteTimeUtc.Ticks;

        if (!_states.TryGetValue(path, out var state))
        {
            state = new FileState();
            _states[path] = state;
            _stampsDirty = true;
        }

        if (state.Seeded && state.LastLength == length && state.LastMtimeTicks == mtime)
        {
            return; // unchanged since the previous poll
        }

        if (length < state.Offset)
        {
            // Shrunk (truncated or replaced): reset and re-read from the start.
            state.Offset = 0;
            state.Partial = Array.Empty<byte>();
            state.Turns.Clear();
            state.SessionId = "";
            _stampsDirty = true;
        }

        if (!state.Seeded && length > BootstrapTailBytes)
        {
            // First sight of a very large file: only parse the trailing window; the
            // first (partial) line fragment is discarded below by the fast filter.
            state.Offset = length - BootstrapTailBytes;
        }

        var from = state.Offset;
        var wanted = Math.Min(length - from, MaxReadPerPollBytes);
        if (wanted > 0)
        {
            byte[] buffer = new byte[wanted];
            using var stream = new FileStream(
                path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            stream.Seek(from, SeekOrigin.Begin);
            var read = 0;
            while (read < buffer.Length)
            {
                var chunk = stream.Read(buffer, read, buffer.Length - read);
                if (chunk <= 0)
                {
                    break;
                }

                read += chunk;
            }

            if (read > 0)
            {
                var combined = state.Partial.Length == 0 ? buffer : state.Partial.Concat(buffer[..read]).ToArray();
                var lastNewline = Array.LastIndexOf(combined, (byte)'\n');
                if (lastNewline < 0)
                {
                    state.Partial = combined;
                }
                else
                {
                    var text = Encoding.UTF8.GetString(combined, 0, lastNewline + 1);
                    state.Partial = combined[(lastNewline + 1)..];
                    foreach (var rawLine in text.Split('\n'))
                    {
                        ProcessLine(state, rawLine.TrimEnd('\r'));
                    }
                }

                state.Offset = from + read;
                _stampsDirty = true;
            }
        }

        state.Seeded = true;
        state.LastLength = length;
        state.LastMtimeTicks = mtime;
    }

    private static void ProcessLine(FileState state, string line)
    {
        if (line.Length == 0 || line[0] != '{')
        {
            return; // fast filter: rollout bodies are JSON objects
        }

        JsonNode? node;
        try
        {
            node = JsonNode.Parse(line);
        }
        catch (JsonException)
        {
            return;
        }

        if (node is null)
        {
            return;
        }

        var type = node.GetString("type");
        if (type.Length == 0)
        {
            return;
        }

        var payload = node["payload"];
        DateTimeOffset? at = null;
        var timestamp = node.GetString("timestamp");
        if (timestamp.Length > 0 && TimeText.TryParseIso(timestamp, out var parsed))
        {
            at = parsed;
        }

        switch (type)
        {
            case "session_meta":
                UpdateSessionId(state, payload);
                return;

            case "turn.started":
                StartTurn(state, TurnIdFrom(payload, node), at);
                return;

            case "turn.completed":
                EndTurn(state, TurnIdFrom(payload, node));
                return;

            case "turn.aborted":
                EndTurn(state, TurnIdFrom(payload, node));
                return;

            case "event_msg":
                HandleEventMessage(state, payload, at);
                return;
        }
    }

    private static void UpdateSessionId(FileState state, JsonNode? payload)
    {
        var id = payload.GetString("id");
        if (id.Length == 0)
        {
            id = payload.GetString("thread_id");
        }

        if (id.Length > 0)
        {
            state.SessionId = id;
        }
    }

    private static void HandleEventMessage(FileState state, JsonNode? payload, DateTimeOffset? at)
    {
        var payloadType = payload.GetString("type");
        var turnId = TurnIdFrom(payload, null);
        switch (payloadType)
        {
            case "task_started":
                StartTurn(state, turnId, at);
                return;

            case "task_complete":
            case "task_completed":
            case "turn_aborted":
            case "task_aborted":
                EndTurn(state, turnId);
                return;

            case "token_count":
                TokenActivity(state, turnId, at);
                return;
        }
    }

    private static string TurnIdFrom(JsonNode? payload, JsonNode? node)
    {
        var id = payload.GetString("turn_id");
        if (id.Length == 0 && node is not null)
        {
            id = node.GetString("turn_id");
        }

        return id.Length == 0 ? LegacyTurnId : id;
    }

    private static void StartTurn(FileState state, string turnId, DateTimeOffset? at)
    {
        if (turnId == LegacyTurnId)
        {
            if (!state.Turns.TryGetValue(LegacyTurnId, out var legacy))
            {
                legacy = new TurnState { TurnId = LegacyTurnId };
                state.Turns[LegacyTurnId] = legacy;
            }

            Refresh(legacy, at);
            return;
        }

        if (!state.Turns.TryGetValue(turnId, out var turn))
        {
            turn = new TurnState { TurnId = turnId };
            state.Turns[turnId] = turn;
        }

        Refresh(turn, at);
    }

    private static void EndTurn(FileState state, string turnId)
    {
        if (turnId.Length == 0 || turnId == LegacyTurnId)
        {
            // "legacy" completions carry no id: clear every turn of the file (macOS parity).
            state.Turns.Clear();
            return;
        }

        // Unknown/terminal turns are simply dropped; orphan terminal events never
        // create work (macOS parity).
        state.Turns.Remove(turnId);
    }

    private static void TokenActivity(FileState state, string turnId, DateTimeOffset? at)
    {
        if (at is null)
        {
            return; // cannot timestamp the activity
        }

        if (turnId != LegacyTurnId && state.Turns.TryGetValue(turnId, out var specific))
        {
            Refresh(specific, at);
            return;
        }

        // Every remembered turn is running by construction (terminal turns are
        // removed immediately), so token flow refreshes them all.
        if (state.Turns.Count > 0)
        {
            foreach (var turn in state.Turns.Values)
            {
                Refresh(turn, at);
            }

            return;
        }

        // Heuristic: tokens are flowing but no turn was ever announced — older CLI
        // rollout shapes have no task_started lines, so imply a running turn.
        state.Turns[ImplicitTurnId] = new TurnState
        {
            TurnId = ImplicitTurnId,
            LastActivityUtc = at.Value,
        };
    }

    private static void Refresh(TurnState turn, DateTimeOffset? at)
    {
        turn.StartedAtUtc ??= at;
        if (at is { } value && (turn.LastActivityUtc == default || value > turn.LastActivityUtc))
        {
            turn.LastActivityUtc = value;
        }
    }

    private List<CodexTaskInfo> BuildActiveTasks()
    {
        var tasks = new List<CodexTaskInfo>();
        foreach (var (path, state) in _states)
        {
            if (state.Turns.Count == 0)
            {
                continue;
            }

            var sessionId = state.SessionId;
            if (sessionId.Length == 0)
            {
                sessionId = Path.GetFileNameWithoutExtension(path);
            }

            var started = DateTimeOffset.MaxValue;
            var lastActivity = DateTimeOffset.MinValue;
            foreach (var turn in state.Turns.Values)
            {
                started = Min(started, turn.StartedAtUtc ?? turn.LastActivityUtc);
                lastActivity = Max(lastActivity, turn.LastActivityUtc);
            }

            tasks.Add(new CodexTaskInfo(sessionId, started, lastActivity, CodexTaskState.Running, CodexTaskSource.Local));
        }

        tasks.Sort((a, b) => a.StartedAtUtc.CompareTo(b.StartedAtUtc));
        return tasks;

        static DateTimeOffset Min(DateTimeOffset left, DateTimeOffset right) => left < right ? left : right;
        static DateTimeOffset Max(DateTimeOffset left, DateTimeOffset right) => left > right ? left : right;
    }

    private void LoadStamps()
    {
        try
        {
            if (Json.TryReadFile(_stampsPath) is not JsonObject map)
            {
                return;
            }

            foreach (var (path, value) in map)
            {
                if (value is not JsonObject entry)
                {
                    continue;
                }

                var length = entry.GetLong("len", -1);
                if (length < 0)
                {
                    continue;
                }

                _states[path] = new FileState
                {
                    Offset = length,
                    LastLength = length,
                    LastMtimeTicks = entry.GetLong("mtime", 0),
                    Seeded = true,
                };
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException)
        {
            // Corrupt stamps behave like "no stamps": files are re-tailed.
        }
    }

    private void PersistStamps()
    {
        if (!_stampsDirty)
        {
            return;
        }

        try
        {
            var map = new JsonObject();
            foreach (var (path, state) in _states)
            {
                map[path] = new JsonObject
                {
                    ["len"] = state.Offset,
                    ["mtime"] = state.LastMtimeTicks,
                };
            }

            Json.AtomicWrite(_stampsPath, map.ToJsonString());
            _stampsDirty = false;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Best effort: unpersisted stamps only cost a re-read next launch.
        }
    }
}
