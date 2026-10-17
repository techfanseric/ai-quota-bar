namespace AQB.CodexTasks;

public enum CodexTaskState
{
    Running = 0,
    Completed = 1,
    Aborted = 2,
}

public enum CodexTaskSource
{
    Hook = 0,
    Local = 1,
}

/// <summary>
/// One active (or recently finished) Codex work item. <see cref="Id"/> is the Codex
/// session id; the monitor unions both sources by that id.
/// </summary>
public sealed record CodexTaskInfo(
    string Id,
    DateTimeOffset StartedAtUtc,
    DateTimeOffset LastActivityUtc,
    CodexTaskState State,
    CodexTaskSource Source);
