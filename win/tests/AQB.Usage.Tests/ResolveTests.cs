using Xunit;

namespace AQB.Usage.Tests;

public class ResolveTests
{
    private static readonly string T0 = "2026-09-01T00:00:00Z";
    private static readonly string T1 = "2026-09-01T00:01:00Z";
    private static readonly string T2 = "2026-09-01T00:02:00Z";
    private static readonly string T3 = "2026-09-01T00:03:00Z";
    private static readonly string T4 = "2026-09-01T00:04:00Z";

    private static readonly UsageTokens A = new(100, 20, 10, 10, 0);
    private static readonly UsageTokens B = new(200, 40, 20, 20, 0);
    private static readonly UsageTokens C = new(500, 100, 0, 50, 0);

    [Fact]
    public void ForkPrefixRecordsAreStripped()
    {
        var parent = CodexSessionScanner.ParseLines(new[]
        {
            Rollout.Meta(T0, "parent"),
            Rollout.TokenCount(T1, "m", last: A),
            Rollout.TokenCount(T2, "m", last: B),
        });
        var child = CodexSessionScanner.ParseLines(new[]
        {
            Rollout.Meta(T2, "child", forkedFrom: "parent"), // started before T3
            Rollout.TokenCount(T1, "m", last: A),            // copied prefix
            Rollout.TokenCount(T2, "m", last: B),            // copied prefix
            Rollout.TokenCount(T3, "m", last: C),            // own usage after fork
        });

        var resolved = CodexSessionScanner.Resolve(new[] { parent, child });

        Assert.Equal(0, resolved.DeferredSessions);
        Assert.Equal(3, resolved.Events.Count);
        // Parent keeps both; the child only contributes its post-fork record.
        Assert.Equal(A.Input + B.Input + C.Input, resolved.Events.Sum(e => e.Tokens.Input));
        Assert.Contains(resolved.Events, e => e.Tokens == C);
    }

    [Fact]
    public void MissingParentDefersWholeSession()
    {
        var child = CodexSessionScanner.ParseLines(new[]
        {
            Rollout.Meta(T0, "child", forkedFrom: "missing-parent"),
            Rollout.TokenCount(T1, "m", last: C),
        });

        var resolved = CodexSessionScanner.Resolve(new[] { child });

        Assert.Equal(1, resolved.DeferredSessions);
        Assert.Contains("child", resolved.DeferredSessionIds);
        Assert.Empty(resolved.Events);
    }

    [Fact]
    public void DeferredSessionResolvesWhenParentAppears()
    {
        var child = CodexSessionScanner.ParseLines(new[]
        {
            Rollout.Meta(T2, "child", forkedFrom: "parent"),
            Rollout.TokenCount(T1, "m", last: A),
            Rollout.TokenCount(T3, "m", last: C),
        });

        Assert.Empty(CodexSessionScanner.Resolve(new[] { child }).Events);

        var parent = CodexSessionScanner.ParseLines(new[]
        {
            Rollout.Meta(T0, "parent"),
            Rollout.TokenCount(T1, "m", last: A),
        });
        var resolved = CodexSessionScanner.Resolve(new[] { parent, child });

        Assert.Equal(0, resolved.DeferredSessions);
        Assert.Equal(2, resolved.Events.Count);
        Assert.Equal(A.Input + C.Input, resolved.Events.Sum(e => e.Tokens.Input));
    }

    [Fact]
    public void RealUsageAfterForkWithRepeatedSignatureIsKept()
    {
        var parent = CodexSessionScanner.ParseLines(new[]
        {
            Rollout.Meta(T0, "parent"),
            Rollout.TokenCount(T1, "m", last: A),
        });
        var child = CodexSessionScanner.ParseLines(new[]
        {
            Rollout.Meta(T1, "child", forkedFrom: "parent"),
            Rollout.TokenCount(T1, "m", last: A), // copied prefix (<= fork cutoff)
            Rollout.TokenCount(T4, "m", last: A), // genuinely new usage, same signature
        });

        var resolved = CodexSessionScanner.Resolve(new[] { parent, child });

        Assert.Equal(0, resolved.DeferredSessions);
        Assert.Equal(2, resolved.Events.Count);
        Assert.Equal(2 * A.Input, resolved.Events.Sum(e => e.Tokens.Input));
    }

    [Fact]
    public void NestedForkStripsInheritedPrefixAtEachLevel()
    {
        var parent = CodexSessionScanner.ParseLines(new[]
        {
            Rollout.Meta(T0, "p"),
            Rollout.TokenCount(T1, "m", last: A),
        });
        var child = CodexSessionScanner.ParseLines(new[]
        {
            Rollout.Meta(T1, "c", forkedFrom: "p"),
            Rollout.TokenCount(T1, "m", last: A), // inherited from p
            Rollout.TokenCount(T2, "m", last: B), // own
        });
        var grandChild = CodexSessionScanner.ParseLines(new[]
        {
            Rollout.Meta(T2, "g", forkedFrom: "c"),
            Rollout.TokenCount(T2, "m", last: B), // inherited from c
            Rollout.TokenCount(T3, "m", last: C), // own
        });

        var resolved = CodexSessionScanner.Resolve(new[] { parent, child, grandChild });

        Assert.Equal(0, resolved.DeferredSessions);
        Assert.Equal(3, resolved.Events.Count);
        Assert.Equal(A.Input + B.Input + C.Input, resolved.Events.Sum(e => e.Tokens.Input));
    }

    [Fact]
    public void ArchivedCopyOfSameSessionCountsOnce()
    {
        var lines = new[]
        {
            Rollout.Meta(T0, "s"),
            Rollout.TokenCount(T1, "m", last: A),
            Rollout.TokenCount(T2, "m", last: B),
        };
        var original = CodexSessionScanner.ParseLines(lines);
        var archived = CodexSessionScanner.ParseLines(lines);

        var resolved = CodexSessionScanner.Resolve(new[] { original, archived });

        Assert.Equal(2, resolved.Events.Count);
        Assert.Equal(A.Input + B.Input, resolved.Events.Sum(e => e.Tokens.Input));
    }

    [Fact]
    public void CumulativeOnlyForkWithoutCopiedPrefixSubtractsParentBaseline()
    {
        // macOS spec: pure-cumulative fork without a copied prefix re-bases on the
        // parent's cumulative baseline so history is not replayed as fresh usage.
        var parent = CodexSessionScanner.ParseLines(new[]
        {
            Rollout.Meta(T0, "p"),
            Rollout.TokenCount(T1, "m", total: new UsageTokens(100, 0, 0, 10, 0)),
        });
        var child = CodexSessionScanner.ParseLines(new[]
        {
            Rollout.Meta(T2, "c", forkedFrom: "p"),
            Rollout.TokenCount(T3, "m", total: new UsageTokens(150, 0, 0, 20, 0)),
        });

        var resolved = CodexSessionScanner.Resolve(new[] { parent, child });

        Assert.Equal(0, resolved.DeferredSessions);
        Assert.Equal(2, resolved.Events.Count);
        // Parent: 100 (baseline start). Child: 150-100 = 50 fresh input.
        Assert.Equal(150, resolved.Events.Sum(e => e.Tokens.Input));
    }

    [Fact]
    public void EventsAreSortedByOccurredAt()
    {
        var file = CodexSessionScanner.ParseLines(new[]
        {
            Rollout.Meta(T0, "s"),
            Rollout.TokenCount(T2, "m", last: B),
            Rollout.TokenCount(T1, "m", last: A),
        });

        var resolved = CodexSessionScanner.Resolve(new[] { file });

        Assert.Equal(2, resolved.Events.Count);
        Assert.True(string.CompareOrdinal(resolved.Events[0].OccurredAt, resolved.Events[1].OccurredAt) < 0);
    }
}
