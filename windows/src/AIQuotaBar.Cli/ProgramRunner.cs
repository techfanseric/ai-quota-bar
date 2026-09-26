// Swift 来源：无（Windows 端新增；命令分发与全局旗标解析）。

#nullable enable

using System.Globalization;

namespace AIQuotaBar.Cli;

internal static class ProgramRunner
{
    public static async Task<int> RunAsync(string[] args)
    {
        // SSH 管道捕获时 PowerShell 侧代码页可能不是 UTF-8：强制控制台输出 UTF-8，中文不糊。
        Console.OutputEncoding = System.Text.Encoding.UTF8;

        // 全局旗标从参数中抽取（可出现在任意位置），剩余按“动词 + 子命令 + 位置参数”解析。
        var rest = new List<string>(args);
        var verbose = rest.RemoveAll(a => a == "--verbose") > 0;
        var json = rest.RemoveAll(a => a == "--json") > 0;
        var proxy = ExtractOption(rest, "--proxy");
        var logFile = ExtractOption(rest, "--log-file");
        var timeoutOption = ExtractOption(rest, "--timeout");

        if (rest.Count > 0 && rest[0] is "help" or "--help" or "-h")
        {
            PrintHelp();
            return 0;
        }

        if (rest.Count > 0 && rest[0] is "version" or "--version")
        {
            CliLog.Init(logFile, verbose);
            var t0 = CliLog.OpBegin("version");
            Console.WriteLine(ThisAssembly.Version());
            CliLog.Op("version", t0);
            return 0;
        }

        CliLog.Init(logFile, verbose);
        CliLog.Info($"aqb {string.Join(' ', args)}");
        CliLog.Info($"log file: {CliLog.LogFilePath}");

        var timeout = TimeSpan.FromSeconds(60);
        if (timeoutOption is not null)
        {
            if (!double.TryParse(timeoutOption, CultureInfo.InvariantCulture, out var seconds) || seconds <= 0)
            {
                Console.Error.WriteLine($"--timeout 需要正数秒数，收到：{timeoutOption}");
                return 2;
            }

            timeout = TimeSpan.FromSeconds(seconds);
        }

        var options = new CliOptions(verbose, json, proxy, timeout);
        if (rest.Count == 0)
        {
            PrintHelp();
            return 2;
        }

        var verb = rest[0].ToLowerInvariant();
        var tail = rest.Skip(1).ToList();
        try
        {
            return verb switch
            {
                "env" => EnvDoctorCommand.RunEnv(options),
                "doctor" => await EnvDoctorCommand.RunDoctorAsync(options).ConfigureAwait(false),
                "selftest" => SelfTestCommand.Run(options),
                "cred" => CredCommand.Run(tail),
                "glm" => await ProviderCommand.RunGlmAsync(tail, options).ConfigureAwait(false),
                "minimax" => await ProviderCommand.RunMinimaxAsync(tail, options).ConfigureAwait(false),
                "clash" => await ClashCommand.RunAsync(tail, options).ConfigureAwait(false),
                _ => Unknown(verb),
            };
        }
        catch (UsageException ex)
        {
            Console.Error.WriteLine(ex.Message);
            CliLog.Error($"usage: {ex.Message}");
            return 2;
        }
        catch (Exception ex)
        {
            CliLog.Exception(verb, ex);
            Console.Error.WriteLine($"失败：{ex.Message}（详情见日志 {CliLog.LogFilePath}）");
            return 1;
        }
    }

    private static int Unknown(string verb)
    {
        Console.Error.WriteLine($"未知命令：{verb}（aqb help 查看用法）");
        return 2;
    }

    private static string? ExtractOption(List<string> args, string name)
    {
        for (var i = 0; i < args.Count; i++)
        {
            if (args[i] == name)
            {
                if (i + 1 >= args.Count)
                {
                    throw new UsageException($"{name} 需要一个值");
                }

                var value = args[i + 1];
                args.RemoveRange(i, 2);
                return value;
            }
        }

        return null;
    }

    private static void PrintHelp()
    {
        Console.WriteLine("""
            AIQuotaBar.Cli — Windows 端控制与测试入口

            用法：aqb <命令> [参数] [全局旗标]

            命令：
              env                          环境报告（OS/会话/路径/凭据库可写性/代理）
              doctor                       综合体检：env + selftest + 网络 + Clash 发现
              selftest                     内置自检（契约 JSON/枚举/DPAPI/数学）
              cred list [service]          列出已存凭据（不含密钥）
              cred write <svc> <acct>      写入凭据（--stdin 从管道读，或 --secret）
              cred read <svc> <acct>       读取凭据（--raw 显示全文）
              cred delete <svc> <acct>     删除凭据
              glm quota --credential <c>   查询 GLM 配额（凭据也可 --credential-file / --from-cred-store）
              glm test --credential <c>    连通性测试
              minimax quota --token <t>    查询 MiniMax 配额（--region global|cn --group <g>）
              minimax test --token <t>     连通性测试
              clash discover               发现本机 Clash 控制器配置
              clash status                 控制器版本与路由组概览
              clash routes                 当前组路由列表
              clash connections            活动连接快照（契约 JSON）
              clash switch <group> <route> 切换路由
              clash test <group>           组内测速
              version / help

            全局旗标：
              --verbose                    DEBUG 级控制台输出
              --json                       配额结果输出完整 JSON（线上契约形状）
              --log-file <path>            覆盖默认日志路径
              --proxy <url>                HTTP 代理（如 http://10.0.0.181:7897）
              --timeout <seconds>          网络超时（默认 60）
            """);
    }
}

/// <summary>全局选项（一次解析、全程传递）。</summary>
internal sealed record CliOptions(bool Verbose, bool Json, string? Proxy, TimeSpan Timeout);

/// <summary>用法错误（退出码 2）。</summary>
internal sealed class UsageException(string message) : Exception(message);

internal static class ThisAssembly
{
    public static string Version() =>
        System.Reflection.Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "0.0.0";
}
