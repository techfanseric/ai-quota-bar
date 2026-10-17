using AQB.Core;
using Xunit;

namespace AQB.Usage.Tests;

public class ParserTests
{
    private static readonly string T0 = "2026-09-01T00:00:00Z";
    private static readonly string T1 = "2026-09-01T00:01:00Z";
    private static readonly string T2 = "2026-09-01T00:02:00Z";
    private static readonly string T3 = "2026-09-01T00:03:00Z";

    private static ParsedUsageFile Parse(params string[] lines) => CodexSessionScanner.ParseLines(lines);

    [Fact]
    public void ParsesAllThreeLineTypes()
    {
        var parsed = Parse(
            Rollout.Meta(T0, "sess-1"),
            Rollout.TurnContext(T1, "GPT-5.3-Codex"),
            Rollout.TokenCount(T2, "gpt-5.3-codex",
                total: new UsageTokens(100, 50, 10, 10, 0),
                last: new UsageTokens(30, 10, 0, 5, 0)));

        Assert.Equal("sess-1", parsed.SessionId);
        Assert.Null(parsed.ParentId);
        Assert.Equal(TimeText.FixedIso(DateTimeOffset.Parse(T0)), parsed.StartedAt);
        Assert.Equal(0, parsed.Issues);
        var record = Assert.Single(parsed.Records);
        Assert.Equal("gpt-5.3-codex", record.Event.Model);
        Assert.Equal(new UsageTokens(30, 10, 0, 5, 0), record.Event.Tokens);
        Assert.Equal("exact", record.Event.Quality);
        Assert.Equal("default", record.Event.LimitId);
        Assert.Equal(TimeText.FixedIso(DateTimeOffset.Parse(T2)), record.Event.OccurredAt);
        Assert.Equal(64, record.Event.Id.Length); // sha256 hex idempotency key
    }

    [Fact]
    public void InfoModelBeatsTurnContextModel()
    {
        var parsed = Parse(
            Rollout.Meta(T0, "s"),
            Rollout.TurnContext(T1, "ctx-model"),
            Rollout.TokenCount(T2, null, last: new UsageTokens(10, 0, 0, 5, 0)),
            Rollout.TokenCount(T3, "info-model", last: new UsageTokens(20, 0, 0, 5, 0)));

        // Line without info.model falls back to the turn_context model.
        Assert.Equal("ctx-model", parsed.Records[0].Event.Model);
        // An explicit info.model wins and then sticks for later lines.
        Assert.Equal("info-model", parsed.Records[1].Event.Model);
    }

    [Fact]
    public void LastTokenUsageIsExactAndBeatsDelta()
    {
        var parsed = Parse(
            Rollout.Meta(T0, "s"),
            Rollout.TokenCount(T1, "m", total: new UsageTokens(100, 50, 10, 10, 0), last: new UsageTokens(25, 5, 0, 5, 0)),
            Rollout.TokenCount(T2, "m", total: new UsageTokens(150, 60, 10, 20, 0), last: new UsageTokens(30, 6, 0, 8, 0)));

        Assert.Equal(2, parsed.Records.Count);
        Assert.All(parsed.Records, r => Assert.Equal("exact", r.Event.Quality));
        Assert.Equal(new UsageTokens(25, 5, 0, 5, 0), parsed.Records[0].Event.Tokens);
        Assert.Equal(new UsageTokens(30, 6, 0, 8, 0), parsed.Records[1].Event.Tokens);
    }

    [Fact]
    public void MissingLastFallsBackToCumulativeDelta()
    {
        var parsed = Parse(
            Rollout.Meta(T0, "s"),
            Rollout.TokenCount(T1, "m", total: new UsageTokens(100, 50, 10, 10, 0)),
            Rollout.TokenCount(T2, "m", total: new UsageTokens(150, 60, 10, 20, 0)));

        Assert.Equal(2, parsed.Records.Count);
        Assert.All(parsed.Records, r => Assert.Equal("cumulative-delta", r.Event.Quality));
        // First cumulative snapshot is taken as-is (baseline start), second is the delta.
        Assert.True(parsed.Records[0].StartsBaseline);
        Assert.Equal(new UsageTokens(100, 50, 10, 10, 0), parsed.Records[0].Event.Tokens);
        Assert.Equal(new UsageTokens(50, 10, 0, 10, 0), parsed.Records[1].Event.Tokens);
    }

    [Fact]
    public void RegressingCumulativeDeltaIsDroppedWithIssue()
    {
        // macOS spec vector: inputs [100,150,10,30] -> records [100,50,20], issues = 1.
        var parsed = Parse(
            Rollout.Meta(T0, "s"),
            Rollout.TokenCount(T1, "m", total: new UsageTokens(100, 0, 0, 10, 0)),
            Rollout.TokenCount(T2, "m", total: new UsageTokens(150, 0, 0, 10, 0)),
            Rollout.TokenCount(T3, "m", total: new UsageTokens(10, 0, 0, 10, 0)),
            Rollout.TokenCount("2026-09-01T00:04:00Z", "m", total: new UsageTokens(30, 0, 0, 10, 0)));

        Assert.Equal(3, parsed.Records.Count);
        Assert.Equal(new long[] { 100, 50, 20 }, parsed.Records.Select(r => r.Event.Tokens.Input).ToArray());
        Assert.Equal(1, parsed.Issues);
    }

    [Fact]
    public void DuplicateSnapshotCountedOnce()
    {
        var total = new UsageTokens(100, 50, 10, 10, 0);
        var last = new UsageTokens(30, 10, 0, 5, 0);
        var parsed = Parse(
            Rollout.Meta(T0, "s"),
            Rollout.TokenCount(T1, "m", total, last),
            Rollout.TokenCount(T2, "m", total, last));

        var record = Assert.Single(parsed.Records);
        Assert.Equal(0, parsed.Issues);
    }

    [Fact]
    public void DuplicateAcrossDifferentLimitIdsStillCountedOnce()
    {
        var total = new UsageTokens(100, 50, 10, 10, 0);
        var last = new UsageTokens(30, 10, 0, 5, 0);
        var parsed = Parse(
            Rollout.Meta(T0, "s"),
            Rollout.TokenCount(T1, "m", total, last, limitId: "default"),
            Rollout.TokenCount(T2, "m", total, last, limitId: "other"));

        Assert.Single(parsed.Records);
    }

    [Fact]
    public void EqualLastOnlyOccurrencesAreNotDeduplicated()
    {
        var last = new UsageTokens(30, 10, 0, 5, 0);
        var parsed = Parse(
            Rollout.Meta(T0, "s"),
            Rollout.TokenCount(T1, "m", last: last),
            Rollout.TokenCount(T2, "m", last: last));

        Assert.Equal(2, parsed.Records.Count);
        Assert.NotEqual(parsed.Records[0].Event.Id, parsed.Records[1].Event.Id);
    }

    [Fact]
    public void ZeroDeltaRecordIsSkippedSilently()
    {
        var parsed = Parse(
            Rollout.Meta(T0, "s"),
            // Reasoning changes so the signature differs (not a duplicate),
            // but input+output stays equal -> zero total delta is dropped.
            Rollout.TokenCount(T1, "m", total: new UsageTokens(100, 50, 10, 10, 0)),
            Rollout.TokenCount(T2, "m", total: new UsageTokens(100, 50, 10, 10, 1)));

        var record = Assert.Single(parsed.Records);
        Assert.Equal(0, parsed.Issues);
        Assert.Equal(110, record.Event.Tokens.Total);
    }

    [Fact]
    public void InvalidCountersDropWholeLineWithIssue()
    {
        var parsed = Parse(
            Rollout.Meta(T0, "s"),
            Rollout.RawTokenCount(T1, "{\"model\":\"m\",\"total_token_usage\":{\"input_tokens\":true,\"output_tokens\":5},\"last_token_usage\":{\"input_tokens\":1,\"output_tokens\":1}}"),
            Rollout.RawTokenCount(T2, "{\"model\":\"m\",\"total_token_usage\":{\"cached_input_tokens\":1,\"output_tokens\":5}}"),
            Rollout.RawTokenCount(T3, "{\"model\":\"m\",\"total_token_usage\":{\"input_tokens\":10,\"cached_input_tokens\":20,\"output_tokens\":5},\"last_token_usage\":{\"input_tokens\":1,\"output_tokens\":1}}"));

        Assert.Empty(parsed.Records);
        Assert.Equal(3, parsed.Issues);
    }

    [Fact]
    public void NonObjectLineCountsAsIssue()
    {
        var parsed = Parse(
            Rollout.Meta(T0, "s"),
            "not a json line",
            "{\"broken\":\"token_count\" line",
            Rollout.Noise(T1));

        Assert.Empty(parsed.Records);
        Assert.Equal(2, parsed.Issues);
        Assert.False(parsed.Incomplete);
    }

    [Fact]
    public void SessionMetaConflictClearsSession()
    {
        var parsed = Parse(
            Rollout.Meta(T0, "child", forkedFrom: "p1", spawnParent: "p2"),
            Rollout.TokenCount(T1, "m", last: new UsageTokens(10, 0, 0, 5, 0)));

        Assert.Null(parsed.SessionId);
        Assert.Equal(2, parsed.Issues); // meta conflict + record without session
        Assert.Empty(parsed.Records);
    }

    [Fact]
    public void ParentEqualToSelfClearsSession()
    {
        var parsed = Parse(
            Rollout.Meta(T0, "same", forkedFrom: "same"),
            Rollout.TokenCount(T1, "m", last: new UsageTokens(10, 0, 0, 5, 0)));

        Assert.Null(parsed.SessionId);
        Assert.Empty(parsed.Records);
        Assert.Equal(2, parsed.Issues);
    }

    [Fact]
    public void SpawnedParentIsRecorded()
    {
        var parsed = Parse(Rollout.Meta(T0, "child", spawnParent: "parent-thread"));

        Assert.Equal("child", parsed.SessionId);
        Assert.Equal("parent-thread", parsed.ParentId);
    }

    [Fact]
    public void OnlyFirstSessionMetaCounts()
    {
        var parsed = Parse(
            Rollout.Meta(T0, "first"),
            Rollout.Meta(T1, "second"),
            Rollout.TokenCount(T2, "m", last: new UsageTokens(10, 0, 0, 5, 0)));

        Assert.Equal("first", parsed.SessionId);
        Assert.Single(parsed.Records);
    }

    [Fact]
    public void RecordWithoutSessionIsRejected()
    {
        var parsed = Parse(
            Rollout.TokenCount(T1, "m", last: new UsageTokens(10, 0, 0, 5, 0)));

        // No session_meta -> no session -> record rejected with an issue, but must not throw.
        Assert.Empty(parsed.Records);
        Assert.Equal(1, parsed.Issues);
    }

    [Fact]
    public void UnknownModelStateUsesUnknownModel()
    {
        // File-level parse keeps model state; with no turn_context and no info model
        // the model stays "unknown" (normalized empty check included).
        var parsed = Parse(
            Rollout.Meta(T0, "s"),
            Rollout.RawTokenCount(T1, "{\"total_token_usage\":{\"input_tokens\":10,\"output_tokens\":5}}"));

        var record = Assert.Single(parsed.Records);
        Assert.Equal("unknown", record.Event.Model);
    }
}
