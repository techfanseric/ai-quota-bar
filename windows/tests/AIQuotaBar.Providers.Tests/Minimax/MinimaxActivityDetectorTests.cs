// Swift 来源：AIQuotaBar/Tests/Providers/MiniMaxActivityDetectorTests.swift — final class MiniMaxActivityDetectorTests。
// 目录路径与 now 全部注入（Swift 同款 Fixture 辅助：临时根 + 会话/后台任务子目录，tearDown 清理 →
// 构造函数 + IDisposable）。manifest.json 为本地文件格式（测试合成，与 Swift 测试同值），非 API 响应。

using System.Text.Json;
using AIQuotaBar.Providers.Minimax;
using Xunit;

namespace AIQuotaBar.Providers.Tests.Minimax;

public sealed class MinimaxActivityDetectorTests : IDisposable
{
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1_000_000);

    private readonly string _rootPath;
    private readonly string _sessionsRootPath;
    private readonly string _backgroundTasksRootPath;
    private readonly MiniMaxActivityDetector _detector;

    public MinimaxActivityDetectorTests()
    {
        _rootPath = Path.Combine(Path.GetTempPath(), "aiqb-minimax-" + Guid.NewGuid().ToString("N"));
        _sessionsRootPath = Path.Combine(_rootPath, "v2", "sessions");
        _backgroundTasksRootPath = Path.Combine(_rootPath, "background-tasks");
        Directory.CreateDirectory(_sessionsRootPath);
        Directory.CreateDirectory(_backgroundTasksRootPath);
        _detector = new MiniMaxActivityDetector(
            _sessionsRootPath, _backgroundTasksRootPath, MiniMaxActivityDetector.DefaultFreshnessWindow);
    }

    public void Dispose()
    {
        try
        {
            Directory.Delete(_rootPath, recursive: true);
        }
        catch (IOException)
        {
            // 临时目录清理失败不影响测试结果（Swift: try? removeItem）。
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    // Swift: testFreshTranscriptActivityMarksSessionActiveEvenWithStaleManifest
    // 回归：CLI 的 manifest.json 可能落后 transcript 数分钟——活动必须来自会话目录文件 mtime。
    [Fact]
    public void FreshTranscriptActivity_MarksSessionActiveEvenWithStaleManifest()
    {
        WriteSession(
            day: "2026/09/24",
            sessionId: "mvs_working",
            manifestUpdatedAtMs: Milliseconds(Now - TimeSpan.FromMinutes(10)),
            fileModifiedAt: Now - TimeSpan.FromSeconds(30));

        var snapshot = _detector.DetectSnapshot(Now);

        Assert.Equal(
            new[] { "minimax:cli:mvs_working" },
            snapshot.ActiveSessionIds.OrderBy(id => id, StringComparer.Ordinal).ToArray());
        Assert.True(
            snapshot.LastEventBySession.TryGetValue("minimax:cli:mvs_working", out var lastEvent),
            "应记录会话最近事件时间（应然），实然缺失。");
        Assert.Equal(
            (Now - TimeSpan.FromSeconds(30)).ToUnixTimeMilliseconds(),
            lastEvent.ToUnixTimeMilliseconds());
    }

    // Swift: testQuietSessionIsIgnored
    [Fact]
    public void QuietSession_IsIgnored()
    {
        WriteSession(
            day: "2026/09/24",
            sessionId: "mvs_old",
            manifestUpdatedAtMs: Milliseconds(Now - TimeSpan.FromMinutes(10)),
            fileModifiedAt: Now - TimeSpan.FromMinutes(10));

        var snapshot = _detector.DetectSnapshot(Now);

        Assert.Empty(snapshot.ActiveSessionIds);
        Assert.Null(snapshot.LastEventAt);
        Assert.Empty(snapshot.LastEventBySession);
    }

    // Swift: testFreshBackgroundTaskIsActive
    [Fact]
    public void FreshBackgroundTask_IsActive()
    {
        WriteBackgroundTask(taskId: "bg_running", modifiedAt: Now - TimeSpan.FromSeconds(20));
        WriteBackgroundTask(taskId: "bg_finished", modifiedAt: Now - TimeSpan.FromMinutes(10));

        var snapshot = _detector.DetectSnapshot(Now);

        Assert.Equal(
            new[] { "minimax:bg:bg_running" },
            snapshot.ActiveSessionIds.OrderBy(id => id, StringComparer.Ordinal).ToArray());
        Assert.True(
            snapshot.LastEventBySession.TryGetValue("minimax:bg:bg_running", out var lastEvent),
            "应记录后台任务最近事件时间（应然），实然缺失。");
        Assert.Equal(
            (Now - TimeSpan.FromSeconds(20)).ToUnixTimeMilliseconds(),
            lastEvent.ToUnixTimeMilliseconds());
    }

    // Swift: testMalformedManifestFallsBackToDirectoryName
    [Fact]
    public void MalformedManifest_FallsBackToDirectoryName()
    {
        var brokenDirectory = Path.Combine(
            _sessionsRootPath, "2026/09/24", "12-00-00-000-session_broken");
        Directory.CreateDirectory(brokenDirectory);
        var brokenManifest = Path.Combine(brokenDirectory, "manifest.json");
        File.WriteAllText(brokenManifest, "not json");
        File.SetLastWriteTimeUtc(brokenManifest, Utc(Now - TimeSpan.FromSeconds(30)));
        Directory.SetLastWriteTimeUtc(brokenDirectory, Utc(Now - TimeSpan.FromSeconds(30)));
        WriteSession(
            day: "2026/09/24",
            sessionId: "mvs_good",
            manifestUpdatedAtMs: Milliseconds(Now - TimeSpan.FromSeconds(30)),
            fileModifiedAt: Now - TimeSpan.FromSeconds(30));

        var snapshot = _detector.DetectSnapshot(Now);

        Assert.Equal(
            new[] { "minimax:cli:12-00-00-000-session_broken", "minimax:cli:mvs_good" },
            snapshot.ActiveSessionIds.OrderBy(id => id, StringComparer.Ordinal).ToArray());
    }

    // Swift: testDayFoldersBeyondTheScanLimitAreIgnored
    // 文件活动本可让历史会话保持活跃；排除它的是日期目录扫描上限（最新两个）。
    [Fact]
    public void DayFoldersBeyondTheScanLimit_AreIgnored()
    {
        WriteSession("2026/09/01", "mvs_history",
            Milliseconds(Now - TimeSpan.FromSeconds(30)), Now - TimeSpan.FromSeconds(30));
        WriteSession("2026/09/15", "mvs_recent",
            Milliseconds(Now - TimeSpan.FromSeconds(30)), Now - TimeSpan.FromSeconds(30));
        WriteSession("2026/09/24", "mvs_current",
            Milliseconds(Now - TimeSpan.FromSeconds(30)), Now - TimeSpan.FromSeconds(30));

        var detector = new MiniMaxActivityDetector(
            _sessionsRootPath, _backgroundTasksRootPath, freshnessWindow: TimeSpan.FromMinutes(10));

        Assert.Equal(
            new[] { "minimax:cli:mvs_current", "minimax:cli:mvs_recent" },
            detector.DetectSnapshot(Now).ActiveSessionIds.OrderBy(id => id, StringComparer.Ordinal).ToArray());
    }

    // Swift: testMissingRootsReturnIdle
    [Fact]
    public void MissingRoots_ReturnIdle()
    {
        var missing = Path.Combine(Path.GetTempPath(), "aiqb-minimax-missing-" + Guid.NewGuid().ToString("N"));
        var detector = new MiniMaxActivityDetector(missing, missing);

        var snapshot = detector.DetectSnapshot(Now);

        Assert.Empty(snapshot.ActiveSessionIds);
        Assert.Null(snapshot.LastEventAt);
        Assert.Empty(snapshot.LastEventBySession);
    }

    // ------------------------------------------------------------------ Fixture 辅助（Swift Fixture struct 同款）

    private static long Milliseconds(DateTimeOffset date) =>
        date.ToUnixTimeMilliseconds();

    private static DateTime Utc(DateTimeOffset date) => date.UtcDateTime;

    private void WriteSession(string day, string sessionId, long manifestUpdatedAtMs, DateTimeOffset fileModifiedAt)
    {
        var sessionDirectory = Path.Combine(_sessionsRootPath, day, $"13-58-25-445-session_{sessionId}");
        Directory.CreateDirectory(sessionDirectory);
        var manifest = new Dictionary<string, object?>
        {
            ["sessionId"] = sessionId,
            ["createdAtMs"] = manifestUpdatedAtMs - 60_000,
            ["updatedAtMs"] = manifestUpdatedAtMs,
            ["schemaVersion"] = 1,
        };
        var manifestPath = Path.Combine(sessionDirectory, "manifest.json");
        File.WriteAllText(manifestPath, JsonSerializer.Serialize(manifest));
        File.SetLastWriteTimeUtc(manifestPath, DateTimeOffset.FromUnixTimeMilliseconds(manifestUpdatedAtMs).UtcDateTime);
        var transcriptPath = Path.Combine(sessionDirectory, "messages.jsonl");
        File.WriteAllText(transcriptPath, "{\"type\":\"message\"}\n");
        File.SetLastWriteTimeUtc(transcriptPath, Utc(fileModifiedAt));
    }

    private void WriteBackgroundTask(string taskId, DateTimeOffset modifiedAt)
    {
        var taskDirectory = Path.Combine(_backgroundTasksRootPath, taskId);
        Directory.CreateDirectory(taskDirectory);
        File.WriteAllText(Path.Combine(taskDirectory, "output.log"), "chunk");
        File.WriteAllText(Path.Combine(taskDirectory, "summary.txt"), "summary");
        File.SetLastWriteTimeUtc(Path.Combine(taskDirectory, "output.log"), Utc(modifiedAt));
        File.SetLastWriteTimeUtc(Path.Combine(taskDirectory, "summary.txt"), Utc(modifiedAt));
        Directory.SetLastWriteTimeUtc(taskDirectory, Utc(modifiedAt));
    }
}
