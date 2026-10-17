using System.Text.Json.Nodes;
using Xunit;

namespace AQB.CodexTasks.Tests;

/// <summary>
/// Covers the stdin-payload -> JSONL mapping used by AQB.Hook/Program.cs.
/// The hook executable itself is a thin transport (read stdin, append, print
/// "{}"); these tests exercise the mapping function directly, no process spawn.
/// </summary>
public sealed class HookPayloadMapperTests
{
    private static readonly DateTimeOffset At = new(2026, 10, 17, 12, 0, 0, TimeSpan.Zero);

    private static JsonNode Payload(string eventName, string? sessionId, string? turnId = null, string? agentId = null)
    {
        var node = new JsonObject { ["hook_event_name"] = eventName };
        if (sessionId is not null)
        {
            node["session_id"] = sessionId;
        }

        if (turnId is not null)
        {
            node["turn_id"] = turnId;
        }

        if (agentId is not null)
        {
            node["agent_id"] = agentId;
        }

        node["cwd"] = @"D:\code";
        return node;
    }

    [Theory]
    [InlineData("UserPromptSubmit", HookEvent.TurnStarted)]
    [InlineData("PreToolUse", HookEvent.TurnStarted)]
    [InlineData("PermissionRequest", HookEvent.TurnStarted)]
    [InlineData("PostToolUse", HookEvent.TurnStarted)]
    [InlineData("SubagentStart", HookEvent.TurnStarted)]
    [InlineData("Stop", HookEvent.TurnStopped)]
    [InlineData("SubagentStop", HookEvent.TurnStopped)]
    [InlineData("SessionEnd", HookEvent.SessionEnd)]
    public void KnownEvents_MapToLogTypes(string eventName, string expectedType)
    {
        var evt = HookPayloadMapper.Map(Payload(eventName, "sess-1", turnId: "turn-1"), At);

        Assert.NotNull(evt);
        Assert.Equal(expectedType, evt!.Type);
        Assert.Equal("sess-1", evt.SessionId);
        if (expectedType != HookEvent.SessionEnd)
        {
            Assert.Equal("turn-1", evt.TurnId);
        }

        Assert.Equal("codex", evt.Provider);
        Assert.Equal("2026-10-17T12:00:00.000Z", evt.At);
    }

    [Fact]
    public void RootStop_WithoutTurnId_MapsToSessionWideStop()
    {
        var evt = HookPayloadMapper.Map(Payload("Stop", "sess-1"), At);

        Assert.NotNull(evt);
        Assert.Equal(HookEvent.TurnStopped, evt!.Type);
        Assert.Null(evt.TurnId);
    }

    [Fact]
    public void MidTurnEvents_WithoutTurnId_AreDropped()
    {
        // macOS parity: events without a turn id never touch turn state.
        Assert.Null(HookPayloadMapper.Map(Payload("PreToolUse", "sess-1"), At));
        Assert.Null(HookPayloadMapper.Map(Payload("PermissionRequest", "sess-1"), At));
        Assert.Null(HookPayloadMapper.Map(Payload("SubagentStop", "sess-1"), At));
    }

    [Fact]
    public void Stop_WithOnlyAgentId_IsDropped()
    {
        // We cannot correlate a subagent stop without its turn id.
        Assert.Null(HookPayloadMapper.Map(Payload("Stop", "sess-1", agentId: "agent-9"), At));
    }

    [Fact]
    public void EmptyTurnId_IsTreatedAsMissing()
    {
        var evt = HookPayloadMapper.Map(Payload("UserPromptSubmit", "sess-1", turnId: "  "), At);

        Assert.NotNull(evt);
        Assert.Null(evt!.TurnId);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void MissingSessionId_MapsToNull(string? sessionId)
    {
        Assert.Null(HookPayloadMapper.Map(Payload("UserPromptSubmit", sessionId), At));
    }

    [Fact]
    public void MissingEventName_MapsToNull()
    {
        var node = new JsonObject { ["session_id"] = "sess-1" };
        Assert.Null(HookPayloadMapper.Map(node, At));
    }

    [Fact]
    public void UnknownEventName_MapsToNull()
    {
        Assert.Null(HookPayloadMapper.Map(Payload("SomethingElse", "sess-1"), At));
    }

    [Fact]
    public void NullPayload_MapsToNull()
    {
        Assert.Null(HookPayloadMapper.Map(null, At));
    }
}
