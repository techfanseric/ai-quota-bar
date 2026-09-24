// Swift 来源：AIQuotaBar/Services/MiniMaxActivityDetector.swift（整文件）。
// 对应测试：AIQuotaBar/Tests/Providers/MiniMaxActivityDetectorTests.swift。
//
// 检测两类本地运行时（只读元数据，永不读消息体 / 工具输出）：
// - MiniMax CLI 会话 ~/.minimax/v2/sessions/<y>/<m>/<d>/：活动 = 会话目录内最新文件 mtime
//   （manifest.json 只提供规范会话 ID —— 实测它可能落后实际写入数分钟）。
// - 后台任务 ~/.minimax/background-tasks/bg_<uuid>/：活动 = output.log / summary.txt / 任务目录 mtime。
// 环境变量 MINIMAX_HOME 可重定向根目录；目录路径注入式，默认值仅供生产装配。

using System.Text.Json;

namespace AIQuotaBar.Providers.Minimax;

/// <summary>MiniMax 本地活动检测器（Swift: MiniMaxActivityDetector）。</summary>
public sealed class MiniMaxActivityDetector
{
    /// <summary>Swift: defaultFreshnessWindow = 120s。</summary>
    public static readonly TimeSpan DefaultFreshnessWindow = TimeSpan.FromSeconds(120);

    /// <summary>
    /// 每轮扫描最近的几个日期目录（YYYY/MM/DD 名排序）。会话创建于启动当日，扫最新两个即可覆盖
    /// 跨午夜仍在工作的任务（Swift: scannedDayFolderLimit = 2）。
    /// </summary>
    public const int ScannedDayFolderLimit = 2;

    private static readonly string[] BackgroundTaskActivityFileNames = { "output.log", "summary.txt" };

    private readonly string _sessionsRootPath;
    private readonly string _backgroundTasksRootPath;
    private readonly TimeSpan _freshnessWindow;

    public MiniMaxActivityDetector(
        string? sessionsRootPath = null,
        string? backgroundTasksRootPath = null,
        TimeSpan? freshnessWindow = null)
    {
        _sessionsRootPath = sessionsRootPath ?? DefaultSessionsRootPath();
        _backgroundTasksRootPath = backgroundTasksRootPath ?? DefaultBackgroundTasksRootPath();
        _freshnessWindow = freshnessWindow ?? DefaultFreshnessWindow;
    }

    /// <summary>Swift: defaultHomeURL —— MINIMAX_HOME 非空优先，否则 ~/.minimax。</summary>
    public static string DefaultHomePath(IReadOnlyDictionary<string, string>? environment = null)
    {
        var configured = environment is not null && environment.TryGetValue("MINIMAX_HOME", out var overridePath)
            ? overridePath
            : Environment.GetEnvironmentVariable("MINIMAX_HOME");
        if (!string.IsNullOrEmpty(configured))
        {
            return configured;
        }
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".minimax");
    }

    /// <summary>Swift: defaultSessionsRootURL —— &lt;home&gt;/v2/sessions。</summary>
    public static string DefaultSessionsRootPath(IReadOnlyDictionary<string, string>? environment = null) =>
        Path.Combine(DefaultHomePath(environment), "v2", "sessions");

    /// <summary>Swift: defaultBackgroundTasksRootURL —— &lt;home&gt;/background-tasks。</summary>
    public static string DefaultBackgroundTasksRootPath(IReadOnlyDictionary<string, string>? environment = null) =>
        Path.Combine(DefaultHomePath(environment), "background-tasks");

    /// <summary>Swift: isClientInstalled —— 任务保护资格的本地存在性检查。</summary>
    public static bool IsClientInstalled(IReadOnlyDictionary<string, string>? environment = null)
    {
        var home = DefaultHomePath(environment);
        return File.Exists(home) || Directory.Exists(home);
    }

    /// <summary>异步入口（Swift: snapshot() 在 detached task 上执行目录扫描）。</summary>
    public async Task<ProviderLocalActivitySnapshot> SnapshotAsync(CancellationToken cancellationToken = default) =>
        await Task.Run(() => DetectSnapshot(DateTimeOffset.UtcNow), cancellationToken).ConfigureAwait(false);

    /// <summary>同步检测核心（Swift: detectSnapshot(now:)），测试注入 now 与目录路径。</summary>
    public ProviderLocalActivitySnapshot DetectSnapshot(DateTimeOffset now)
    {
        var cutoff = now - _freshnessWindow;
        var activeSessionIds = new HashSet<string>(StringComparer.Ordinal);
        var lastEventBySession = new Dictionary<string, DateTimeOffset>(StringComparer.Ordinal);
        DateTimeOffset? lastEventAt = null;

        void Record(string prefixedSessionId, DateTimeOffset activityAt)
        {
            activeSessionIds.Add(prefixedSessionId);
            lastEventBySession[prefixedSessionId] = activityAt;
            if (lastEventAt is null || activityAt > lastEventAt)
            {
                lastEventAt = activityAt;
            }
        }

        foreach (var sessionDirectory in RecentSessionDirectories())
        {
            var activityAt = NewestFileModification(sessionDirectory);
            if (activityAt is null || activityAt < cutoff || activityAt > now)
            {
                continue;
            }
            var sessionId = ReadSessionId(sessionDirectory)
                ?? Path.GetFileName(sessionDirectory);
            Record($"minimax:cli:{sessionId}", activityAt.Value);
        }

        foreach (var taskDirectory in BackgroundTaskDirectories())
        {
            var activityAt = NewestBackgroundTaskModification(taskDirectory);
            if (activityAt is null || activityAt < cutoff || activityAt > now)
            {
                continue;
            }
            Record($"minimax:bg:{Path.GetFileName(taskDirectory)}", activityAt.Value);
        }

        return new ProviderLocalActivitySnapshot(activeSessionIds, lastEventAt, lastEventBySession);
    }

    // ------------------------------------------------------------------ CLI 会话

    private IReadOnlyList<string> RecentSessionDirectories()
    {
        var directories = new List<string>();
        foreach (var dayFolder in SortedDayFolderPaths().Take(ScannedDayFolderLimit))
        {
            var dayPath = Path.Combine(_sessionsRootPath, dayFolder);
            foreach (var entry in EnumerateNonHiddenEntries(dayPath))
            {
                if (!Directory.Exists(entry))
                {
                    continue;
                }
                if (!Path.GetFileName(entry).Contains("session_", StringComparison.Ordinal))
                {
                    continue;
                }
                directories.Add(entry);
            }
        }
        return directories;
    }

    /// <summary>
    /// 相对 sessions 根的日期目录路径，新→旧排序。布局是 &lt;year&gt;/&lt;month&gt;/&lt;day&gt;，
    /// 拼接路径的字典序与时间序一致（Swift: sortedDayFolderPaths）。
    /// </summary>
    private IReadOnlyList<string> SortedDayFolderPaths()
    {
        var paths = new List<string>();
        foreach (var year in EnumerateNonHiddenDirectories(_sessionsRootPath))
        {
            foreach (var month in EnumerateNonHiddenDirectories(year))
            {
                foreach (var day in EnumerateNonHiddenDirectories(month))
                {
                    paths.Add($"{Path.GetFileName(year)}/{Path.GetFileName(month)}/{Path.GetFileName(day)}");
                }
            }
        }
        return paths.OrderByDescending(path => path, StringComparer.Ordinal).ToList();
    }

    /// <summary>manifest.json 只用于规范会话 ID；缺失/损坏返回 null（回退目录名）。</summary>
    private string? ReadSessionId(string sessionDirectory)
    {
        var manifestPath = Path.Combine(sessionDirectory, "manifest.json");
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(manifestPath));
            if (document.RootElement.ValueKind == JsonValueKind.Object
                && document.RootElement.TryGetProperty("sessionId", out var value)
                && value.ValueKind == JsonValueKind.String
                && value.GetString() is { Length: > 0 } sessionId)
            {
                return sessionId;
            }
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        {
            // Swift: try? Data(contentsOf:) / try? JSONSerialization —— 静默回退。
        }
        return null;
    }

    // ------------------------------------------------------------------ 后台任务

    private IReadOnlyList<string> BackgroundTaskDirectories() =>
        EnumerateNonHiddenDirectories(_backgroundTasksRootPath)
            .Where(entry => Path.GetFileName(entry).StartsWith("bg_", StringComparison.Ordinal))
            .ToList();

    // ------------------------------------------------------------------ 共享辅助

    /// <summary>
    /// 目录直接子条目的最新 mtime。原位写不更新目录自身 mtime，必须逐条 stat（Swift 注释原意）。
    /// </summary>
    private DateTimeOffset? NewestFileModification(string directory)
    {
        DateTimeOffset? newest = null;
        foreach (var entry in EnumerateNonHiddenEntries(directory))
        {
            DateTimeOffset modified;
            try
            {
                var attributes = File.GetAttributes(entry);
                modified = (attributes & FileAttributes.Directory) == FileAttributes.Directory
                    ? new DateTimeOffset(Directory.GetLastWriteTimeUtc(entry))
                    : new DateTimeOffset(File.GetLastWriteTimeUtc(entry));
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                continue;
            }
            if (newest is null || modified > newest)
            {
                newest = modified;
            }
        }
        return newest;
    }

    /// <summary>后台任务目录自身 + output.log / summary.txt 的最新 mtime。</summary>
    private DateTimeOffset? NewestBackgroundTaskModification(string directory)
    {
        var dates = new List<DateTimeOffset>();
        try
        {
            dates.Add(new DateTimeOffset(Directory.GetLastWriteTimeUtc(directory)));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // 目录 stat 失败继续尝试文件。
        }
        foreach (var fileName in BackgroundTaskActivityFileNames)
        {
            var filePath = Path.Combine(directory, fileName);
            if (File.Exists(filePath))
            {
                dates.Add(new DateTimeOffset(File.GetLastWriteTimeUtc(filePath)));
            }
        }
        return dates.Count == 0 ? null : dates.Max();
    }

    /// <summary>跳过隐藏条目（Swift .skipsHiddenFiles：名字以 "." 开头）的目录枚举，失败返回空。</summary>
    private static IEnumerable<string> EnumerateNonHiddenDirectories(string path)
    {
        List<string> entries;
        try
        {
            // 枚举是惰性的，必须物化到 try 内才能捕获“目录不存在 / 无权限”。
            entries = Directory.EnumerateDirectories(path).ToList();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            yield break;
        }
        foreach (var entry in entries)
        {
            if (!Path.GetFileName(entry).StartsWith(".", StringComparison.Ordinal))
            {
                yield return entry;
            }
        }
    }

    private static IEnumerable<string> EnumerateNonHiddenEntries(string path)
    {
        List<string> entries;
        try
        {
            entries = Directory.EnumerateFileSystemEntries(path).ToList();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            yield break;
        }
        foreach (var entry in entries)
        {
            if (!Path.GetFileName(entry).StartsWith(".", StringComparison.Ordinal))
            {
                yield return entry;
            }
        }
    }
}
