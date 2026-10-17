using AQB.Core;

namespace AQB.CodexTasks;

/// <summary>
/// Merges the two Codex task sources (codex.md §4.1):
///   - hook source: events appended by the AQB.Hook process to the HookEventLog;
///   - local source: <see cref="CodexRolloutWatcher"/> tail-parsing rollout files.
/// The union is deduplicated by session id (the hook source wins because it has
/// reliable turn start times). Ghost turns are recycled after a 10-minute TTL,
/// and the merged list is capped at 99 tasks.
/// </summary>
public sealed class CodexTaskMonitor : IDisposable
{
    public static readonly TimeSpan DefaultPollInterval = TimeSpan.FromSeconds(2);
    public static readonly TimeSpan DefaultTurnTtl = TimeSpan.FromMinutes(10);
    public const int TaskCountLimit = 99;
    private const string RootTurnKey = "root";

    private sealed class HookTurn
    {
        public string SessionId = "";
        public string TurnId = "";
        public DateTimeOffset StartedAtUtc;
        public DateTimeOffset LastEventAtUtc;
    }

    private readonly HookEventLog? _log;
    private readonly CodexRolloutWatcher? _watcher;
    private readonly Func<DateTimeOffset> _utcNow;
    private readonly TimeSpan _turnTtl;
    private readonly Timer? _timer;
    private readonly object _gate = new();
    private readonly Dictionary<string, HookTurn> _hookTurns = new(StringComparer.Ordinal);
    private readonly Dictionary<string, CodexTaskInfo> _localTasks = new(StringComparer.Ordinal);

    // Local sessions pruned by the TTL: remembered so the watcher re-reporting the
    // same stale turn does not resurrect it. Cleared once the task is genuinely gone
    // or its activity moves past the tombstone time.
    private readonly Dictionary<string, DateTimeOffset> _localTombstones = new(StringComparer.Ordinal);
    private IReadOnlyList<CodexTaskInfo> _activeTasks = Array.Empty<CodexTaskInfo>();
    private int _processedHookEvents;
    private bool _disposed;

    /// <summary>Raised (possibly on a timer thread) whenever the active-task set changes.</summary>
    public event EventHandler<IReadOnlyList<CodexTaskInfo>>? ActiveTasksChanged;

    public CodexTaskMonitor(
        HookEventLog? log = null,
        CodexRolloutWatcher? watcher = null,
        TimeSpan? pollInterval = null,
        Func<DateTimeOffset>? utcNow = null,
        TimeSpan? turnTtl = null,
        bool autoStart = true)
    {
        _log = log;
        _watcher = watcher;
        _utcNow = utcNow ?? (static () => DateTimeOffset.UtcNow);
        _turnTtl = turnTtl ?? DefaultTurnTtl;
        var interval = pollInterval ?? DefaultPollInterval;
        if (autoStart && interval > TimeSpan.Zero)
        {
            _timer = new Timer(
                _ =>
                {
                    try
                    {
                        PollOnce();
                    }
                    catch
                    {
                        // A failed poll must never kill the timer thread.
                    }
                },
                null, interval, interval);
        }
    }

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

    public int ActiveCount
    {
        get
        {
            lock (_gate)
            {
                return _activeTasks.Count;
            }
        }
    }

    /// <summary>Runs one merge cycle. Called automatically on a timer; public for tests.</summary>
    public void PollOnce()
    {
        EventHandler<IReadOnlyList<CodexTaskInfo>>? handler = null;
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }

            var now = _utcNow();
            if (_log is not null)
            {
                ApplyHookEvents(_log.ReadAll(), now);
            }

            if (_watcher is not null)
            {
                try
                {
                    _watcher.Poll();
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                }

                MergeLocal(_watcher.ActiveTasks, now);
            }

            PruneStaleHookTurns(now);
            var merged = RebuildActive();
            if (!SameSet(merged, _activeTasks))
            {
                _activeTasks = merged;
                handler = ActiveTasksChanged;
            }
        }

        handler?.Invoke(this, ActiveTasks);
    }

    public void Dispose()
    {
        lock (_gate)
        {
            _disposed = true;
        }

        _timer?.Dispose();
    }

    private void ApplyHookEvents(List<HookEvent> events, DateTimeOffset now)
    {
        if (events.Count < _processedHookEvents)
        {
            // The log was compacted/rotated behind our cursor: replay from scratch.
            _processedHookEvents = 0;
            _hookTurns.Clear();
        }

        for (var i = _processedHookEvents; i < events.Count; i++)
        {
            ApplyHookEvent(events[i], now);
        }

        _processedHookEvents = events.Count;
    }

    private void ApplyHookEvent(HookEvent evt, DateTimeOffset now)
    {
        if (!TimeText.TryParseIso(evt.At, out var at))
        {
            at = now;
        }

        switch (evt.Type)
        {
            case HookEvent.TurnStarted:
                var turnId = evt.TurnId is { Length: > 0 } id ? id : RootTurnKey;
                var key = evt.SessionId + "|" + turnId;
                if (!_hookTurns.TryGetValue(key, out var turn))
                {
                    _hookTurns[key] = new HookTurn
                    {
                        SessionId = evt.SessionId,
                        TurnId = turnId,
                        // StartedAt keeps the earliest sighting (macOS: startedAt 取最早).
                        StartedAtUtc = at,
                        LastEventAtUtc = at,
                    };
                }
                else if (at > turn.LastEventAtUtc)
                {
                    turn.LastEventAtUtc = at;
                }

                return;

            case HookEvent.TurnStopped:
                if (evt.TurnId is { Length: > 0 } stoppedId)
                {
                    _hookTurns.Remove(evt.SessionId + "|" + stoppedId);
                }
                else
                {
                    // Root stop without a turn id: stop every turn of the session.
                    RemoveSession(evt.SessionId);
                }

                return;

            case HookEvent.SessionEnd:
                RemoveSession(evt.SessionId);
                return;
        }
    }

    private void RemoveSession(string sessionId)
    {
        foreach (var key in _hookTurns.Keys
                     .Where(key => string.Equals(_hookTurns[key].SessionId, sessionId, StringComparison.Ordinal))
                     .ToList())
        {
            _hookTurns.Remove(key);
        }
    }

    private void PruneStaleHookTurns(DateTimeOffset now)
    {
        foreach (var key in _hookTurns.Keys
                     .Where(key => now - _hookTurns[key].LastEventAtUtc >= _turnTtl)
                     .ToList())
        {
            // Ghost recycling: kill -9 / lost Stop hooks cannot pin protection forever.
            _hookTurns.Remove(key);
        }
    }

    private void MergeLocal(IReadOnlyList<CodexTaskInfo> reported, DateTimeOffset now)
    {
        var currentIds = new HashSet<string>(StringComparer.Ordinal);
        foreach (var task in reported)
        {
            currentIds.Add(task.Id);
            if (_localTombstones.TryGetValue(task.Id, out var deadSince) && task.LastActivityUtc <= deadSince)
            {
                continue; // still the same stale turn the TTL already recycled
            }

            _localTombstones.Remove(task.Id);
            _localTasks[task.Id] = task;
        }

        foreach (var gone in _localTasks.Keys.Where(key => !currentIds.Contains(key)).ToList())
        {
            _localTasks.Remove(gone);
        }

        foreach (var gone in _localTombstones.Keys.Where(key => !currentIds.Contains(key)).ToList())
        {
            _localTombstones.Remove(gone);
        }

        // TTL for the local source: stale running turns (no terminal line, no token
        // flow) are tombstoned instead of surfacing forever.
        foreach (var stale in _localTasks
                     .Where(pair => now - pair.Value.LastActivityUtc >= _turnTtl)
                     .Select(pair => (pair.Key, pair.Value.LastActivityUtc))
                     .ToList())
        {
            _localTasks.Remove(stale.Key);
            _localTombstones[stale.Key] = stale.LastActivityUtc;
        }
    }

    private List<CodexTaskInfo> RebuildActive()
    {
        var tasks = new List<CodexTaskInfo>();

        // Hook sessions: one entry per session, earliest turn start.
        foreach (var group in _hookTurns.Values.GroupBy(turn => turn.SessionId))
        {
            var started = group.Min(turn => turn.StartedAtUtc);
            var last = group.Max(turn => turn.LastEventAtUtc);
            tasks.Add(new CodexTaskInfo(group.Key, started, last, CodexTaskState.Running, CodexTaskSource.Hook));
        }

        // Local sessions, deduplicated by session id (hook wins).
        foreach (var task in _localTasks.Values)
        {
            if (tasks.Any(existing => string.Equals(existing.Id, task.Id, StringComparison.Ordinal)))
            {
                continue;
            }

            tasks.Add(task);
        }

        tasks.Sort((a, b) => a.StartedAtUtc.CompareTo(b.StartedAtUtc));
        return tasks.Count > TaskCountLimit ? tasks[..TaskCountLimit] : tasks;
    }

    private static bool SameSet(IReadOnlyList<CodexTaskInfo> left, IReadOnlyList<CodexTaskInfo> right)
    {
        if (left.Count != right.Count)
        {
            return false;
        }

        for (var i = 0; i < left.Count; i++)
        {
            if (!string.Equals(left[i].Id, right[i].Id, StringComparison.Ordinal)
                || left[i].State != right[i].State)
            {
                return false;
            }
        }

        return true;
    }
}
