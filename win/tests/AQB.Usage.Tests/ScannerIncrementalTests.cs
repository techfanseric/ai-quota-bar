using System.Text.Json.Nodes;
using Xunit;

namespace AQB.Usage.Tests;

public class ScannerIncrementalTests
{
    private static readonly string T0 = "2026-10-01T00:00:00Z";
    private static readonly string T1 = "2026-10-01T00:01:00Z";
    private static readonly string T2 = "2026-10-01T00:02:00Z";
    private static readonly string T3 = "2026-10-01T00:03:00Z";

    private static CodexSessionScanner Scanner(TempDir dir)
        => new(Path.Combine(dir.Root, "codex"), Path.Combine(dir.Root, "appdata", "stamps.json"));

    private static string Line(string s) => s + "\n";

    [Fact]
    public void UnchangedFilesAreSkippedOnRescan()
    {
        using var dir = new TempDir();
        dir.WriteFile(@"codex\sessions\a.jsonl",
            Line(Rollout.Meta(T0, "s")) + Line(Rollout.TokenCount(T1, "m", last: new UsageTokens(100, 0, 0, 10, 0))));
        var scanner = Scanner(dir);

        var first = scanner.Scan();
        Assert.Equal(1, first.FilesParsed);
        Assert.Equal(0, first.FilesSkipped);
        Assert.Single(first.Events);

        var second = scanner.Scan();
        Assert.Equal(0, second.FilesParsed);
        Assert.Equal(1, second.FilesSkipped);
        Assert.Single(second.Events);

        Assert.True(File.Exists(scanner.StampsPath));
    }

    [Fact]
    public void GrownFileParsesOnlyTheAppendedTail()
    {
        using var dir = new TempDir();
        var path = @"codex\sessions\a.jsonl";
        var head = Line(Rollout.Meta(T0, "s")) + Line(Rollout.TokenCount(T1, "m", last: new UsageTokens(100, 0, 0, 10, 0)));
        dir.WriteFile(path, head);
        var scanner = Scanner(dir);

        var first = scanner.Scan();
        Assert.Single(first.Events);
        Assert.Equal(head.Length, ConsumedBytes(scanner));

        var tail = Line(Rollout.TokenCount(T2, "m", last: new UsageTokens(200, 0, 0, 20, 0)));
        dir.AppendFile(path, tail);
        var second = scanner.Scan();

        Assert.Equal(1, second.FilesParsed);   // same file, changed stamp
        Assert.Equal(0, second.FilesSkipped);
        Assert.Equal(2, second.Events.Count);  // old record preserved + new tail
        Assert.Equal(300, second.Events.Sum(e => e.Tokens.Input));
        // The persisted byte offset advanced by exactly the appended tail.
        Assert.Equal(head.Length + tail.Length, ConsumedBytes(scanner));
    }

    [Fact]
    public void PartialTailIsCompletedOnNextScan()
    {
        using var dir = new TempDir();
        var path = @"codex\sessions\a.jsonl";
        var line1 = Line(Rollout.TokenCount(T1, "m", last: new UsageTokens(100, 0, 0, 10, 0)));
        var line2 = Line(Rollout.TokenCount(T2, "m", last: new UsageTokens(200, 0, 0, 20, 0)));
        var full = Line(Rollout.Meta(T0, "s")) + line1 + line2;
        dir.WriteFile(path, Line(Rollout.Meta(T0, "s")) + line1 + line2[..20]);
        var scanner = Scanner(dir);

        // First scan sees a torn trailing line; the complete record is already visible.
        var first = scanner.Scan();
        Assert.Single(first.Events);

        File.WriteAllText(Path.Combine(dir.Root, path), full);
        var second = scanner.Scan();
        Assert.Equal(2, second.Events.Count);
        Assert.Equal(300, second.Events.Sum(e => e.Tokens.Input));
    }

    private static long ConsumedBytes(CodexSessionScanner scanner)
    {
        var stamps = Assert.IsType<JsonObject>(JsonNode.Parse(File.ReadAllText(scanner.StampsPath)));
        var entry = Assert.Single(stamps);
        return entry.Value!["length"]!.GetValue<long>();
    }

    [Fact]
    public void ShrinkingFileTriggersFullReread()
    {
        using var dir = new TempDir();
        var path = @"codex\sessions\a.jsonl";
        dir.WriteFile(path,
            Line(Rollout.Meta(T0, "s1"))
            + Line(Rollout.TokenCount(T1, "m", last: new UsageTokens(100, 0, 0, 10, 0)))
            + Line(Rollout.TokenCount(T2, "m", last: new UsageTokens(200, 0, 0, 20, 0))));
        var scanner = Scanner(dir);
        Assert.Equal(2, scanner.Scan().Events.Count);

        // Rewrite smaller with different content: old records must disappear.
        File.WriteAllText(Path.Combine(dir.Root, path),
            Line(Rollout.Meta(T0, "s1"))
            + Line(Rollout.TokenCount(T3, "m", last: new UsageTokens(50, 0, 0, 5, 0))));
        var second = scanner.Scan();

        Assert.Single(second.Events);
        Assert.Equal(50, second.Events[0].Tokens.Input);
    }

    [Fact]
    public void StampsSurviveScannerRecreation()
    {
        using var dir = new TempDir();
        dir.WriteFile(@"codex\sessions\a.jsonl",
            Line(Rollout.Meta(T0, "s")) + Line(Rollout.TokenCount(T1, "m", last: new UsageTokens(100, 0, 0, 10, 0))));
        var scanner = Scanner(dir);
        scanner.Scan();

        // New scanner instance (app restart) with the same stamps file skips unchanged files.
        var restarted = Scanner(dir);
        var scan = restarted.Scan();
        Assert.Equal(0, scan.FilesParsed);
        Assert.Equal(1, scan.FilesSkipped);
        Assert.Single(scan.Events);
    }

    [Fact]
    public void DeletedFileDropsItsRecords()
    {
        using var dir = new TempDir();
        var path = dir.WriteFile(@"codex\sessions\a.jsonl",
            Line(Rollout.Meta(T0, "s")) + Line(Rollout.TokenCount(T1, "m", last: new UsageTokens(100, 0, 0, 10, 0))));
        var scanner = Scanner(dir);
        Assert.Single(scanner.Scan().Events);

        File.Delete(path);
        Assert.Empty(scanner.Scan().Events);
    }

    [Fact]
    public void ArchivedSessionsDirectoryIsScanned()
    {
        using var dir = new TempDir();
        dir.WriteFile(@"codex\archived_sessions\b.jsonl",
            Line(Rollout.Meta(T0, "s")) + Line(Rollout.TokenCount(T1, "m", last: new UsageTokens(100, 0, 0, 10, 0))));
        var scanner = Scanner(dir);

        var scan = scanner.Scan();
        Assert.Equal(1, scan.FilesSeen);
        Assert.Single(scan.Events);
    }

    [Fact]
    public void NestedSubdirectoriesAreScanned()
    {
        using var dir = new TempDir();
        dir.WriteFile(@"codex\sessions\2026\10\01\c.jsonl",
            Line(Rollout.Meta(T0, "s")) + Line(Rollout.TokenCount(T1, "m", last: new UsageTokens(100, 0, 0, 10, 0))));
        var scanner = Scanner(dir);

        Assert.Single(scanner.Scan().Events);
    }

    [Fact]
    public void MissingDirectoriesYieldEmptyResult()
    {
        using var dir = new TempDir();
        var scan = Scanner(dir).Scan();

        Assert.Equal(0, scan.FilesSeen);
        Assert.Equal(0, scan.FilesParsed);
        Assert.Equal(0, scan.Issues);
        Assert.Empty(scan.Events);
    }

    [Fact]
    public void SessionsPathOccupiedByFileCountsOneIssue()
    {
        using var dir = new TempDir();
        dir.WriteFile("codex/sessions", "not a directory");
        var scan = Scanner(dir).Scan();

        Assert.Equal(1, scan.Issues);
        Assert.Empty(scan.Events);
    }

    [Fact]
    public void HiddenFilesAreSkipped()
    {
        using var dir = new TempDir();
        dir.WriteFile(@"codex\sessions\.hidden.jsonl",
            Line(Rollout.Meta(T0, "s")) + Line(Rollout.TokenCount(T1, "m", last: new UsageTokens(100, 0, 0, 10, 0))));
        dir.WriteFile(@"codex\sessions\visible.jsonl",
            Line(Rollout.Meta(T0, "s2")) + Line(Rollout.TokenCount(T1, "m", last: new UsageTokens(50, 0, 0, 5, 0))));
        var scan = Scanner(dir).Scan();

        Assert.Equal(1, scan.FilesSeen);
        Assert.Equal(50, scan.Events.Single().Tokens.Input);
    }
}
