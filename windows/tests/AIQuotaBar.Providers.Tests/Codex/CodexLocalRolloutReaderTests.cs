// Swift 来源：
//   - .dependencies/codexbar/Tests/CodexBarTests/AgentSessionParserTests.swift（session_meta 首行语义）
//   - Tests/CodexLocalUsageCoreTests/UsageTests.swift（仓库根 Tests/，App 自有 target 测试——
//     非 .dependencies/codexbar；testRepeatedQuotaSnapshotsAndIdenticalRealRequests：
//     相同时间戳不同 limit_id 不去重、相同 limit_id 或相同签名去重）
// fixtures：local-session-rollout.jsonl、local-session-token-usage.jsonl。

#nullable enable

using System;
using System.Linq;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using AIQuotaBar.Providers.Codex.Parsing;
using Xunit;

namespace AIQuotaBar.Providers.Tests.Codex;

public sealed class CodexLocalRolloutReaderTests
{
    [Fact]
    public void ParseSessionMeta_ReadsFixtureFirstLine()
    {
        var lines = CodexFixtures.ReadLines("local-session-rollout.jsonl");

        var metadata = CodexLocalRolloutReader.ParseSessionMeta(lines[0]);

        Assert.NotNull(metadata);
        Assert.Equal("019f-session-fixture", metadata!.SessionId);
        Assert.Equal("/Users/test/Projects/alpha", metadata.Cwd);
        Assert.Equal("codex_exec", metadata.Originator);
        Assert.Equal("exec", metadata.Source);
    }

    [Fact]
    public void ParseSessionMeta_IgnoresNonMetaLines()
    {
        // 契约：解析器只读首行 session_meta，后续任意行不得使解析失败。
        var lines = CodexFixtures.ReadLines("local-session-rollout.jsonl");

        Assert.Null(CodexLocalRolloutReader.ParseSessionMeta(lines[1]));
    }

    [Fact]
    public async Task ReadSessionMetaAsync_ReadsOnlyFirstLine()
    {
        var path = System.IO.Path.Combine(CodexFixtures.Directory, "local-session-rollout.jsonl");

        var metadata = await CodexLocalRolloutReader.ReadSessionMetaAsync(path);

        Assert.NotNull(metadata);
        Assert.Equal("019f-session-fixture", metadata!.SessionId);
        Assert.Equal("codex_exec", metadata.Originator);
    }

    [Fact]
    public async Task ReadTokenUsageAsync_DedupesRepeatedSnapshots()
    {
        // Swift: testRepeatedQuotaSnapshotsAndIdenticalRealRequests —— 4 条 token_count：
        // (default, t1) 记录；(other, t1) 与上一条签名相同被去重；(default, t1) 重复去重；
        // (default, t2) 新事件。最终 2 条，token 总量 220（input 100+100, output 10+10）。
        var path = System.IO.Path.Combine(CodexFixtures.Directory, "local-session-token-usage.jsonl");

        var result = await CodexLocalRolloutReader.ReadTokenUsageAsync(path);

        Assert.Equal("session", result.SessionId);
        Assert.Equal(new DateTimeOffset(2026, 9, 1, 0, 0, 0, TimeSpan.Zero), result.StartedAt);
        Assert.Equal(0, result.Issues);

        Assert.Equal(2, result.Events.Count);

        var first = result.Events[0];
        Assert.Equal(new DateTimeOffset(2026, 9, 1, 0, 0, 1, TimeSpan.Zero), first.Timestamp);
        Assert.Equal("gpt-test", first.Model);
        Assert.Equal("default", first.LimitId);
        Assert.Equal("exact", first.Quality);
        Assert.Equal(100, first.Tokens.Input);
        Assert.Equal(50, first.Tokens.Cached);
        Assert.Equal(0, first.Tokens.CacheWrite);
        Assert.Equal(10, first.Tokens.Output);
        Assert.Equal(0, first.Tokens.Reasoning);

        var second = result.Events[1];
        Assert.Equal(new DateTimeOffset(2026, 9, 1, 0, 0, 2, TimeSpan.Zero), second.Timestamp);
        Assert.Equal("default", second.LimitId);
        Assert.Equal(100, second.Tokens.Input);

        // Swift UsageSummary 断言口径：tokens.total = Σ(input+output) = 220；缓存命中率 0.5。
        Assert.Equal(220, result.Events.Sum(e => e.Tokens.Total));
        Assert.Equal(0.5, (double)result.Events.Sum(e => e.Tokens.Cached) / result.Events.Sum(e => e.Tokens.Input));
    }

    [Fact]
    public void ReadTokenUsage_InlineModelOverridesTurnContextModel()
    {
        // Swift（Sources/CodexLocalUsageCore/UsageParser.swift）: token_count 行内 model
        // （info.model ?? info.model_name ?? payload.model）覆盖 turn_context 的模型。
        var lines = CodexFixtures.ReadLines("local-session-token-usage.jsonl").ToList();
        var tokenLine = JsonNode.Parse(lines[2]) as JsonObject;
        ((JsonObject)tokenLine!["payload"]!["info"]!)["model"] = "gpt-inline";

        var result = CodexLocalRolloutReader.ReadTokenUsage(
            lines.Take(2).Append(tokenLine!.ToJsonString()));

        var single = Assert.Single(result.Events);
        Assert.Equal("gpt-inline", single.Model);
    }

    [Fact]
    public void ReadTokenUsage_CountsGarbageLineAsIssue()
    {
        var lines = CodexFixtures.ReadLines("local-session-token-usage.jsonl")
            .Append("not json")
            .ToList();

        var result = CodexLocalRolloutReader.ReadTokenUsage(lines);

        Assert.Equal(2, result.Events.Count);
        Assert.Equal(1, result.Issues);
    }
}
