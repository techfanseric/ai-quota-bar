// Swift 来源：无（Windows 端新增；CLI 的统一日志器）。
// 设计约定（计划 §0 执行期裁决：SSH 网络会话写不了凭据库——诊断类信息必须全程留痕）：
// - 每次运行追加写入 %LOCALAPPDATA%\AIQuotaBar\logs\cli-yyyyMMdd.log（无需 --verbose，落盘无条件）；
// - 控制台默认 INFO 级，--verbose 开 DEBUG 级；
// - 每条命令以 [op name] 开始、[op name done Xms] 结束，错误带完整异常链。

#nullable enable

using System.Text;

namespace AIQuotaBar.Cli;

/// <summary>CLI 统一日志器：控制台 + 文件双写。</summary>
internal static class CliLog
{
    private static readonly object Gate = new();
    private static string? _logFilePath;
    private static bool _verbose;

    /// <summary>初始化；fileOverride 为空时用默认路径（延迟创建目录与文件）。</summary>
    public static void Init(string? fileOverride, bool verbose)
    {
        _verbose = verbose;
        var dir = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        _logFilePath = string.IsNullOrWhiteSpace(fileOverride)
            ? Path.Combine(dir, "AIQuotaBar", "logs", $"cli-{DateTime.Now:yyyyMMdd}.log")
            : Path.GetFullPath(Environment.ExpandEnvironmentVariables(fileOverride));
        var parent = Path.GetDirectoryName(_logFilePath);
        if (!string.IsNullOrEmpty(parent))
        {
            Directory.CreateDirectory(parent);
        }

        File.AppendAllText(
            _logFilePath,
            $"===== AIQuotaBar.Cli pid={Environment.ProcessId} start {DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} ====={Environment.NewLine}",
            Encoding.UTF8);
    }

    /// <summary>本次运行的日志文件绝对路径（Init 之后有效）。</summary>
    public static string LogFilePath => _logFilePath ?? string.Empty;

    public static void Debug(string message) => Write("DEBUG", message, ConsoleColor.DarkGray, toConsole: _verbose);

    public static void Info(string message) => Write("INFO ", message, ConsoleColor.Gray, toConsole: true);

    public static void Warn(string message) => Write("WARN ", message, ConsoleColor.Yellow, toConsole: true, stderr: false);

    public static void Error(string message) => Write("ERROR", message, ConsoleColor.Red, toConsole: true, stderr: true);

    /// <summary>记录一条操作区间（含耗时），返回该区间的毫秒数。</summary>
    public static long Op(string name, long startTicks)
    {
        var ms = (DateTime.UtcNow.Ticks - startTicks) / TimeSpan.TicksPerMillisecond;
        Info($"[op {name} done {ms}ms]");
        return ms;
    }

    /// <summary>操作起点日志；返回起点 tick 供 <see cref="Op"/> 收尾。</summary>
    public static long OpBegin(string name)
    {
        Info($"[op {name}]");
        return DateTime.UtcNow.Ticks;
    }

    public static void Exception(string operation, Exception ex)
    {
        Error($"{operation} 失败：{ex.GetType().Name}: {ex.Message}");
        var depth = 0;
        for (var inner = ex.InnerException; inner is not null && depth < 5; inner = inner.InnerException, depth++)
        {
            Error($"  ↳ inner[{depth}]: {inner.GetType().Name}: {inner.Message}");
        }

        Debug(ex.StackTrace ?? "(no stack)");
    }

    private static void Write(string level, string message, ConsoleColor color, bool toConsole, bool stderr = false)
    {
        var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {level} {message}";
        lock (Gate)
        {
            if (_logFilePath is not null)
            {
                try
                {
                    File.AppendAllText(_logFilePath, line + Environment.NewLine, Encoding.UTF8);
                }
                catch (IOException)
                {
                    // 日志落盘失败不能影响主操作（磁盘满/权限异常时仅丢日志）。
                }
            }

            if (toConsole)
            {
                var prev = Console.ForegroundColor;
                Console.ForegroundColor = color;
                if (stderr)
                {
                    Console.Error.WriteLine(line);
                }
                else
                {
                    Console.WriteLine(line);
                }

                Console.ForegroundColor = prev;
            }
        }
    }
}
