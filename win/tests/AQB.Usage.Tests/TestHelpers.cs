using System.Text.Json.Nodes;

namespace AQB.Usage.Tests;

/// <summary>Temp directory fixture for rollout trees and app-data caches.</summary>
public sealed class TempDir : IDisposable
{
    public TempDir()
    {
        Root = Directory.CreateTempSubdirectory("aqb-usage-tests-").FullName;
    }

    public string Root { get; }

    public string CreateDir(string relative)
    {
        var path = System.IO.Path.Combine(Root, relative);
        Directory.CreateDirectory(path);
        return path;
    }

    public string WriteFile(string relative, string content)
    {
        var path = System.IO.Path.Combine(Root, relative);
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
        File.WriteAllText(path, content);
        return path;
    }

    public string AppendFile(string relative, string content)
    {
        var path = System.IO.Path.Combine(Root, relative);
        File.AppendAllText(path, content);
        return path;
    }

    public void Dispose()
    {
        try
        {
            Directory.Delete(Root, recursive: true);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }
}

/// <summary>Builders for Codex rollout JSONL lines (codex.md §3 shapes).</summary>
public static class Rollout
{
    public static string Meta(string timestamp, string id, string? forkedFrom = null, string? spawnParent = null)
    {
        var payload = new JsonObject { ["id"] = id };
        if (forkedFrom is not null)
        {
            payload["forked_from_id"] = forkedFrom;
        }

        if (spawnParent is not null)
        {
            payload["source"] = new JsonObject
            {
                ["subagent"] = new JsonObject
                {
                    ["thread_spawn"] = new JsonObject { ["parent_thread_id"] = spawnParent },
                },
            };
        }

        return new JsonObject
        {
            ["timestamp"] = timestamp,
            ["type"] = "session_meta",
            ["payload"] = payload,
        }.ToJsonString();
    }

    public static string TurnContext(string timestamp, string model, string? accountId = null)
    {
        var payload = new JsonObject { ["model"] = model };
        if (accountId is not null)
        {
            payload["chatgpt_account_id"] = accountId;
        }

        return new JsonObject
        {
            ["timestamp"] = timestamp,
            ["type"] = "turn_context",
            ["payload"] = payload,
        }.ToJsonString();
    }

    public static string TokenCount(string timestamp, string? model,
        UsageTokens? total = null, UsageTokens? last = null, string limitId = "default")
    {
        var info = new JsonObject();
        if (model is not null)
        {
            info["model"] = model;
        }
        if (total is { } t)
        {
            info["total_token_usage"] = Counters(t);
        }

        if (last is { } l)
        {
            info["last_token_usage"] = Counters(l);
        }

        var payload = new JsonObject
        {
            ["type"] = "token_count",
            ["info"] = info,
            ["rate_limits"] = new JsonObject { ["limit_id"] = limitId },
        };
        return new JsonObject
        {
            ["timestamp"] = timestamp,
            ["type"] = "event_msg",
            ["payload"] = payload,
        }.ToJsonString();
    }

    /// <summary>Raw line with arbitrary info JSON (for invalid-counter cases).</summary>
    public static string RawTokenCount(string timestamp, string infoJson)
        => "{\"timestamp\":\"" + timestamp + "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":"
           + infoJson + ",\"rate_limits\":{\"limit_id\":\"default\"}}}";

    /// <summary>Conversation content line: starts with '{' but is not a tracked type.</summary>
    public static string Noise(string timestamp)
        => "{\"timestamp\":\"" + timestamp
           + "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":\"just chat\"}}";

    private static JsonObject Counters(UsageTokens tokens) => new()
    {
        ["input_tokens"] = tokens.Input,
        ["cached_input_tokens"] = tokens.Cached,
        ["cache_write_input_tokens"] = tokens.CacheWrite,
        ["output_tokens"] = tokens.Output,
        ["reasoning_output_tokens"] = tokens.Reasoning,
    };
}

public static class EventFactory
{
    private static int _counter;

    /// <summary>Hand-built event with a unique signature (for aggregator-level tests).</summary>
    public static LocalUsageEvent Event(string occurredAt, string model, UsageTokens tokens,
        string quality = "exact", string limitId = "default", string? signature = null)
        => new()
        {
            Id = $"event-{_counter++}",
            OccurredAt = occurredAt,
            Model = model,
            Tokens = tokens,
            Quality = quality,
            LimitId = limitId,
            Signature = signature ?? $"sig-{_counter}",
        };

    public static UsagePrice Price(string model, decimal input, decimal cached, decimal? cacheWrite, decimal output,
        string effectiveFrom = "2020-01-01T00:00:00Z", string? effectiveTo = null)
        => new()
        {
            Model = model,
            Version = "test-v1",
            Source = "test",
            EffectiveFrom = effectiveFrom,
            EffectiveTo = effectiveTo,
            Input = input,
            Cached = cached,
            CacheWrite = cacheWrite,
            Output = output,
        };
}
