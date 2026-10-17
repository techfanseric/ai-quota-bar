using Xunit;

namespace AQB.CodexTasks.Tests;

public sealed class CodexTaskMonitorTests : IDisposable
{
    private readonly TempDir _dir = new();
    private readonly MutableClock _clock = new();

    public void Dispose() => _dir.Dispose();

    private HookEventLog NewLog() => new(_dir.File("task-events.jsonl"));

    private CodexRolloutWatcher NewWatcher() => new(_dir.Path, _dir.File("rollout-stamps.json"));

    private void Append(string type, string sessionId, string? turnId, int atSeconds)
    {
        NewLog().Append(new HookEvent
        {
            Type = type,
            SessionId = sessionId,
            TurnId = turnId,
            At = Iso.Write(new DateTimeOffset(2026, 10, 17, 12, 0, atSeconds, TimeSpan.Zero)),
        });
    }

    private CodexTaskMonitor Monitor(bool autoStart = false, TimeSpan? ttl = null) => new(
        NewLog(),
        NewWatcher(),
        pollInterval: TimeSpan.FromMilliseconds(10),
        utcNow: _clock.AsFunc(),
        turnTtl: ttl,
        autoStart: autoStart);

    [Fact]
    public void HookTurnLifecycle_StartedThenStopped()
    {
        using var monitor = Monitor();
        Append(HookEvent.TurnStarted, "sess-1", "turn-1", atSeconds: 0);
        monitor.PollOnce();

        Assert.Equal(1, monitor.ActiveCount);
        Assert.Equal("sess-1", monitor.ActiveTasks[0].Id);
        Assert.Equal(CodexTaskSource.Hook, monitor.ActiveTasks[0].Source);

        Append(HookEvent.TurnStopped, "sess-1", "turn-1", atSeconds: 5);
        monitor.PollOnce();
        Assert.Equal(0, monitor.ActiveCount);
    }

    [Fact]
    public void RootStop_WithoutTurnId_ClearsWholeSession()
    {
        using var monitor = Monitor();
        Append(HookEvent.TurnStarted, "sess-1", "turn-a", atSeconds: 0);
        Append(HookEvent.TurnStarted, "sess-1", "turn-b", atSeconds: 1);
        monitor.PollOnce();
        Assert.Equal(1, monitor.ActiveCount); // one session, two turns

        Append(HookEvent.TurnStopped, "sess-1", null, atSeconds: 2);
        monitor.PollOnce();
        Assert.Equal(0, monitor.ActiveCount);
    }

    [Fact]
    public void SessionEnd_ClearsOnlyItsOwnSession()
    {
        using var monitor = Monitor();
        Append(HookEvent.TurnStarted, "sess-1", "turn-1", atSeconds: 0);
        Append(HookEvent.TurnStarted, "sess-2", "turn-1", atSeconds: 0);
        monitor.PollOnce();
        Assert.Equal(2, monitor.ActiveCount);

        Append(HookEvent.SessionEnd, "sess-1", null, atSeconds: 3);
        monitor.PollOnce();

        Assert.Equal(1, monitor.ActiveCount);
        Assert.Equal("sess-2", monitor.ActiveTasks[0].Id);
    }

    [Fact]
    public void Union_DeduplicatesBySessionId_HookWins()
    {
        var rollout = Path.Combine(_dir.Path, "sessions", "rollout.jsonl");
        Directory.CreateDirectory(Path.GetDirectoryName(rollout)!);
        File.WriteAllLines(rollout, new[]
        {
            "{\"timestamp\":\"2026-10-17T12:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"sess-1\"}}",
            "{\"timestamp\":\"2026-10-17T12:00:01.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"local-turn\"}}",
        });
        Append(HookEvent.TurnStarted, "sess-1", "hook-turn", atSeconds: 0);
        Append(HookEvent.TurnStarted, "sess-2", "hook-turn", atSeconds: 0);

        using var monitor = Monitor();
        monitor.PollOnce();

        Assert.Equal(2, monitor.ActiveCount);
        Assert.Contains(monitor.ActiveTasks, task => task.Id == "sess-1" && task.Source == CodexTaskSource.Hook);
        Assert.Contains(monitor.ActiveTasks, task => task.Id == "sess-2" && task.Source == CodexTaskSource.Hook);
    }

    [Fact]
    public void LocalOnlySession_IsSurfaced_WithoutHookEvents()
    {
        var rollout = Path.Combine(_dir.Path, "sessions", "rollout.jsonl");
        Directory.CreateDirectory(Path.GetDirectoryName(rollout)!);
        File.WriteAllLines(rollout, new[]
        {
            "{\"timestamp\":\"2026-10-17T12:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"sess-local\"}}",
            "{\"timestamp\":\"2026-10-17T12:00:01.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"t\"}}",
        });

        using var monitor = Monitor();
        monitor.PollOnce();

        var task = Assert.Single(monitor.ActiveTasks);
        Assert.Equal("sess-local", task.Id);
        Assert.Equal(CodexTaskSource.Local, task.Source);
    }

    [Fact]
    public void GhostHookTurn_IsRecycledAfterTenMinuteTtl()
    {
        using var monitor = Monitor();
        Append(HookEvent.TurnStarted, "sess-ghost", "turn-1", atSeconds: 0);

        _clock.Set(new DateTimeOffset(2026, 10, 17, 12, 0, 0, TimeSpan.Zero));
        monitor.PollOnce();
        Assert.Equal(1, monitor.ActiveCount);

        _clock.Advance(TimeSpan.FromMinutes(10) - TimeSpan.FromSeconds(1));
        monitor.PollOnce();
        Assert.Equal(1, monitor.ActiveCount); // 9m59s: still alive

        _clock.Advance(TimeSpan.FromSeconds(1)); // exactly 10 minutes
        monitor.PollOnce();
        Assert.Equal(0, monitor.ActiveCount);
    }

    [Fact]
    public void LocalGhostTurn_IsTombstoned_NotResurrectedByReReporting()
    {
        var path = Path.Combine(_dir.Path, "sessions", "rollout.jsonl");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var started = "{\"timestamp\":\"2026-10-17T12:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"sess-l\"}}\n"
            + "{\"timestamp\":\"2026-10-17T12:00:01.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"t\"}}\n";
        File.WriteAllText(path, started);

        using var monitor = Monitor();
        _clock.Set(new DateTimeOffset(2026, 10, 17, 12, 0, 1, TimeSpan.Zero));
        monitor.PollOnce();
        Assert.Equal(1, monitor.ActiveCount);

        _clock.Advance(TimeSpan.FromMinutes(11));
        monitor.PollOnce();
        Assert.Equal(0, monitor.ActiveCount); // pruned by TTL

        // The watcher still reports the turn (no terminal line ever appeared) but the
        // tombstone keeps it from coming back until activity actually moves forward.
        monitor.PollOnce();
        Assert.Equal(0, monitor.ActiveCount);

        // New token flow advances LastActivity past the tombstone: accepted again.
        File.AppendAllText(
            path,
            "{\"timestamp\":\"2026-10-17T12:11:30.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{}}}\n");
        monitor.PollOnce();
        Assert.Equal(1, monitor.ActiveCount);
    }

    [Fact]
    public void TaskCount_IsCappedAt99()
    {
        for (var i = 0; i < 150; i++)
        {
            Append(HookEvent.TurnStarted, "sess-" + i, "turn-1", atSeconds: 0);
        }

        using var monitor = Monitor();
        monitor.PollOnce();

        Assert.Equal(99, monitor.ActiveCount);
    }

    [Fact]
    public void ActiveTasksChanged_FiresOnlyForSetChanges()
    {
        using var monitor = Monitor();
        var notifications = 0;
        monitor.ActiveTasksChanged += (_, _) => notifications++;

        Append(HookEvent.TurnStarted, "sess-1", "turn-1", atSeconds: 0);
        monitor.PollOnce();
        Assert.Equal(1, notifications);

        monitor.PollOnce(); // unchanged set
        Assert.Equal(1, notifications);

        Append(HookEvent.TurnStopped, "sess-1", "turn-1", atSeconds: 1);
        monitor.PollOnce();
        Assert.Equal(2, notifications);
    }

    [Fact]
    public async Task TimerDrivenPolling_PicksUpNewEvents()
    {
        // The 2s production interval is injectable; 10ms here.
        var log = NewLog();
        using var monitor = new CodexTaskMonitor(
            log,
            null,
            pollInterval: TimeSpan.FromMilliseconds(10),
            autoStart: true);

        var signal = new TaskCompletionSource();
        monitor.ActiveTasksChanged += (_, _) => signal.TrySetResult();

        log.Append(new HookEvent
        {
            Type = HookEvent.TurnStarted,
            SessionId = "sess-timer",
            TurnId = "turn-1",
            At = Iso.Write(DateTimeOffset.UtcNow),
        });

        var completed = await Task.WhenAny(signal.Task, Task.Delay(TimeSpan.FromSeconds(5)));
        Assert.Same(signal.Task, completed);
        Assert.Equal(1, monitor.ActiveCount);
    }
}
