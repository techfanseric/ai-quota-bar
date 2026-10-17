using Xunit;

namespace AQB.CodexTasks.Tests;

public sealed class CodexRolloutWatcherTests : IDisposable
{
    private readonly TempDir _dir = new();

    public void Dispose() => _dir.Dispose();

    private string Home => _dir.Path;

    private string Sessions => Path.Combine(Home, "sessions");

    private string Stamps => _dir.File("rollout-stamps.json");

    private static string Line(string type, string? payload = null, string timestamp = "2026-10-17T12:00:00.000Z") =>
        payload is null
            ? $"{{\"timestamp\":\"{timestamp}\",\"type\":\"{type}\"}}"
            : $"{{\"timestamp\":\"{timestamp}\",\"type\":\"{type}\",\"payload\":{payload}}}";

    private static string EventMsg(string payloadType, string? turnId = null, string timestamp = "2026-10-17T12:00:00.000Z") =>
        Line("event_msg", turnId is null
            ? $"{{\"type\":\"{payloadType}\"}}"
            : $"{{\"type\":\"{payloadType}\",\"turn_id\":\"{turnId}\"}}", timestamp);

    private void WriteRollout(string name, params string[] lines)
    {
        Directory.CreateDirectory(Sessions);
        File.WriteAllLines(Path.Combine(Sessions, name), lines);
    }

    private static void AppendRollout(string path, params string[] lines) => File.AppendAllLines(path, lines);

    [Fact]
    public void TaskStarted_ThenTaskComplete_ActiveToggles()
    {
        WriteRollout("a.jsonl",
            Line("session_meta", "{\"id\":\"sess-a\"}"),
            EventMsg("task_started", "turn-1"));

        var watcher = new CodexRolloutWatcher(Home, Stamps);
        watcher.Poll();

        var active = Assert.Single(watcher.ActiveTasks);
        Assert.Equal("sess-a", active.Id);
        Assert.Equal(CodexTaskState.Running, active.State);
        Assert.Equal(CodexTaskSource.Local, active.Source);

        var path = Path.Combine(Sessions, "a.jsonl");
        AppendRollout(path, EventMsg("task_complete", "turn-1"));
        watcher.Poll();

        Assert.Empty(watcher.ActiveTasks);
    }

    [Fact]
    public void TopLevelTurnTypes_AreRecognized()
    {
        WriteRollout("b.jsonl",
            Line("session_meta", "{\"id\":\"sess-b\"}"),
            Line("turn.started", "{\"turn_id\":\"turn-9\"}"));

        var watcher = new CodexRolloutWatcher(Home, Stamps);
        watcher.Poll();
        Assert.Single(watcher.ActiveTasks);

        var path = Path.Combine(Sessions, "b.jsonl");
        AppendRollout(path, Line("turn.aborted", "{\"turn_id\":\"turn-9\"}"));
        watcher.Poll();
        Assert.Empty(watcher.ActiveTasks);
    }

    [Fact]
    public void LegacyCompletion_ClearsEveryTurn()
    {
        WriteRollout("c.jsonl",
            Line("session_meta", "{\"id\":\"sess-c\"}"),
            EventMsg("task_started", "turn-1"),
            EventMsg("task_started", "turn-2"));

        var watcher = new CodexRolloutWatcher(Home, Stamps);
        watcher.Poll();
        Assert.Single(watcher.ActiveTasks); // one session entry regardless of turn count

        AppendRollout(Path.Combine(Sessions, "c.jsonl"), EventMsg("task_complete")); // no turn_id -> legacy
        watcher.Poll();
        Assert.Empty(watcher.ActiveTasks);
    }

    [Fact]
    public void TokenCount_WithoutStartedLine_ImpliesActiveTurn()
    {
        WriteRollout("d.jsonl",
            Line("session_meta", "{\"id\":\"sess-d\"}"),
            EventMsg("token_count", timestamp: "2026-10-17T12:00:05.000Z"));

        var watcher = new CodexRolloutWatcher(Home, Stamps);
        watcher.Poll();

        var active = Assert.Single(watcher.ActiveTasks);
        Assert.Equal("sess-d", active.Id);
        Assert.Equal(
            new DateTimeOffset(2026, 10, 17, 12, 0, 5, TimeSpan.Zero),
            active.LastActivityUtc);
    }

    [Fact]
    public void Stamps_PersistAcrossWatcherRestarts()
    {
        var path = Path.Combine(Sessions, "e.jsonl");
        WriteRollout("e.jsonl",
            Line("session_meta", "{\"id\":\"sess-e\"}"),
            EventMsg("task_started", "turn-1"));

        var first = new CodexRolloutWatcher(Home, Stamps);
        first.Poll();
        Assert.Single(first.ActiveTasks);
        Assert.True(File.Exists(Stamps));

        // A fresh watcher (app restart) continues from the persisted offset.
        var second = new CodexRolloutWatcher(Home, Stamps);
        AppendRollout(path, EventMsg("task_complete", "turn-1"));
        second.Poll();

        Assert.Empty(second.ActiveTasks);
    }

    [Fact]
    public void ShrunkFile_IsReReadFromScratch()
    {
        var path = Path.Combine(Sessions, "f.jsonl");
        WriteRollout("f.jsonl",
            Line("session_meta", "{\"id\":\"sess-f\"}"),
            EventMsg("task_started", "turn-1"));

        var watcher = new CodexRolloutWatcher(Home, Stamps);
        watcher.Poll();
        Assert.Single(watcher.ActiveTasks);

        // Truncate to a shorter content without the started line.
        File.WriteAllLines(path, new[] { Line("session_meta", "{\"id\":\"sess-f\"}") });
        watcher.Poll();

        Assert.Empty(watcher.ActiveTasks);
    }

    [Fact]
    public void PartialLine_StaysPending_UntilCompleted()
    {
        var path = Path.Combine(Sessions, "g.jsonl");
        Directory.CreateDirectory(Sessions);
        File.WriteAllText(
            path,
            Line("session_meta", "{\"id\":\"sess-g\"}") + "\n" +
            EventMsg("task_started", "turn-1")[..^10]); // cut mid-JSON

        var watcher = new CodexRolloutWatcher(Home, Stamps);
        watcher.Poll();
        Assert.Empty(watcher.ActiveTasks); // half a line is not visible yet

        // Complete the line; the pending prefix is stitched to the new bytes.
        File.AppendAllText(path, EventMsg("task_started", "turn-1")[^10..] + "\n");
        watcher.Poll();
        Assert.Single(watcher.ActiveTasks);
    }

    [Fact]
    public void TwoSessions_BothReported_OrderedByStart()
    {
        WriteRollout("h1.jsonl",
            Line("session_meta", "{\"id\":\"sess-h1\"}"),
            EventMsg("task_started", "turn-1", "2026-10-17T12:05:00.000Z"));
        WriteRollout("h2.jsonl",
            Line("session_meta", "{\"id\":\"sess-h2\"}"),
            EventMsg("task_started", "turn-1", "2026-10-17T12:01:00.000Z"));

        var watcher = new CodexRolloutWatcher(Home, Stamps);
        watcher.Poll();

        Assert.Equal(2, watcher.ActiveTasks.Count);
        Assert.Equal("sess-h2", watcher.ActiveTasks[0].Id); // started earlier
        Assert.Equal("sess-h1", watcher.ActiveTasks[1].Id);
    }

    [Fact]
    public void MissingSessionsDirectory_IsNotAnError()
    {
        var watcher = new CodexRolloutWatcher(Home, Stamps);
        watcher.Poll();
        Assert.Empty(watcher.ActiveTasks);
    }

    [Fact]
    public void UnchangedFiles_AreNotReParsed_AndStampsStayQuiet()
    {
        WriteRollout("i.jsonl",
            Line("session_meta", "{\"id\":\"sess-i\"}"),
            EventMsg("task_started", "turn-1"));

        var watcher = new CodexRolloutWatcher(Home, Stamps);
        watcher.Poll();

        var stampsAfterFirst = File.ReadAllText(Stamps);
        watcher.Poll();

        Assert.Single(watcher.ActiveTasks);
        Assert.Equal(stampsAfterFirst, File.ReadAllText(Stamps));
    }
}
