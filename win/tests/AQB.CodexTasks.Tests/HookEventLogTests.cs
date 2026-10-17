using Xunit;

namespace AQB.CodexTasks.Tests;

public sealed class HookEventLogTests : IDisposable
{
    private readonly TempDir _dir = new();

    public void Dispose() => _dir.Dispose();

    [Fact]
    public void AppendThenRead_RoundTrips()
    {
        var log = new HookEventLog(_dir.File("task-events.jsonl"));
        var at = Iso.Write(new DateTimeOffset(2026, 10, 17, 12, 0, 0, TimeSpan.Zero));
        log.Append(new HookEvent
        {
            Type = HookEvent.TurnStarted,
            SessionId = "sess-1",
            TurnId = "turn-1",
            At = at,
        });
        log.Append(new HookEvent
        {
            Type = HookEvent.SessionEnd,
            SessionId = "sess-1",
            At = at,
        });

        var events = log.ReadAll();

        Assert.Equal(2, events.Count);
        Assert.Equal(HookEvent.TurnStarted, events[0].Type);
        Assert.Equal("sess-1", events[0].SessionId);
        Assert.Equal("turn-1", events[0].TurnId);
        Assert.Equal(at, events[0].At);
        Assert.Equal("codex", events[0].Provider);
        Assert.Null(events[1].TurnId);
    }

    [Fact]
    public void Read_SkipsBadLines_AndKeepsValidOnes()
    {
        var path = _dir.File("task-events.jsonl");
        File.WriteAllLines(path, new[]
        {
            "{\"type\":\"turn.started\",\"sessionId\":\"s1\",\"at\":\"2026-10-17T12:00:00.000Z\",\"provider\":\"codex\"}",
            "not json at all",
            "{\"type\":\"\",\"sessionId\":\"s2\"}",                       // empty type -> invalid
            "{\"type\":\"turn.stopped\"}",                                // missing session -> invalid
            "{ broken json",
            "{\"type\":\"session.end\",\"sessionId\":\"s1\",\"at\":\"2026-10-17T12:01:00.000Z\"}",
        });

        var events = new HookEventLog(path).ReadAll();

        Assert.Equal(2, events.Count);
        Assert.Equal("turn.started", events[0].Type);
        Assert.Equal("s1", events[0].SessionId);
        Assert.Equal("session.end", events[1].Type);
    }

    [Fact]
    public void Read_MissingFile_ReturnsEmpty()
    {
        var log = new HookEventLog(_dir.File("does-not-exist.jsonl"));

        Assert.Empty(log.ReadAll());
    }

    [Fact]
    public void Clear_RemovesTheLog()
    {
        var path = _dir.File("task-events.jsonl");
        var log = new HookEventLog(path);
        log.Append(new HookEvent { Type = HookEvent.SessionEnd, SessionId = "s", At = Iso.Write(DateTimeOffset.UtcNow) });
        Assert.Single(log.ReadAll());

        log.Clear();

        Assert.Empty(log.ReadAll());
    }
}
