using System.Text.Json.Nodes;
using AQB.Core;

namespace AQB.CodexTasks;

/// <summary>
/// Maps a Codex hook stdin payload ({hook_event_name, session_id, turn_id?, agent_id?, cwd?})
/// onto a normalized <see cref="HookEvent"/> for the JSONL log. Stateless, mirroring the
/// macOS AIQuotaBarHook: payloads without a non-empty hook_event_name and session_id map to
/// null (silent exit). This is the exact mapping AQB.Hook/Program.cs writes; it is unit
/// tested directly instead of spawning the hook process.
///
/// Mapping of the 8 registered hook events (codex.md §4.2):
///   UserPromptSubmit                     -> turn.started  (turn lifecycle start)
///   PreToolUse / PermissionRequest /
///   PostToolUse / SubagentStart          -> turn.started  (activity refresh, requires turn_id)
///   Stop                                 -> turn.stopped  (root stop, or a specific turn via turn_id)
///   SubagentStop                         -> turn.stopped  (requires turn_id)
///   SessionEnd                           -> session.end
/// Anything else (including a Stop carrying only an agent_id we cannot correlate) -> null.
/// </summary>
public static class HookPayloadMapper
{
    public static HookEvent? Map(JsonNode? payload, DateTimeOffset? occurredAtUtc = null)
    {
        if (payload is null)
        {
            return null;
        }

        var eventName = Normalize(payload.GetString("hook_event_name"));
        var sessionId = Normalize(payload.GetString("session_id"));
        if (eventName is null || sessionId is null)
        {
            return null;
        }

        var turnId = Normalize(payload.GetString("turn_id"));
        var agentId = Normalize(payload.GetString("agent_id"));
        var at = TimeText.FixedIso(occurredAtUtc ?? DateTimeOffset.UtcNow);

        switch (eventName)
        {
            case "UserPromptSubmit":
                return Started(sessionId, turnId, at);

            case "Stop":
                if (turnId is not null)
                {
                    return Stopped(sessionId, turnId, at);
                }

                return agentId is null
                    ? Stopped(sessionId, null, at) // root stop without turn id: stop the session's turns
                    : null; // subagent stop we cannot correlate to a turn

            case "SessionEnd":
                return new HookEvent { Type = HookEvent.SessionEnd, SessionId = sessionId, At = at };

            case "PreToolUse":
            case "PermissionRequest":
            case "PostToolUse":
            case "SubagentStart":
                // Mid-turn activity: refreshes the turn's TTL but never creates a
                // turn we cannot identify (macOS: events without turn id don't touch turns).
                return turnId is not null ? Started(sessionId, turnId, at) : null;

            case "SubagentStop":
                return turnId is not null ? Stopped(sessionId, turnId, at) : null;

            default:
                return null;
        }
    }

    private static HookEvent Started(string sessionId, string? turnId, string at) => new()
    {
        Type = HookEvent.TurnStarted,
        SessionId = sessionId,
        TurnId = turnId,
        At = at,
    };

    private static HookEvent Stopped(string sessionId, string? turnId, string at) => new()
    {
        Type = HookEvent.TurnStopped,
        SessionId = sessionId,
        TurnId = turnId,
        At = at,
    };

    private static string? Normalize(string value) =>
        string.IsNullOrWhiteSpace(value) ? null : value.Trim();
}
