// Swift 来源：无（Windows 端新增；环境诊断与综合体检）。
// 背景（计划 §0 执行期发现）：OpenSSH 网络会话按 Windows 设计写不了凭据保管库
// （cmdkey 报 "Credentials cannot be saved from this logon session"），
// env/doctor 必须把会话可写性作为一等公民报告，远程测试才不踩坑。

#nullable enable

using System.Diagnostics;
using System.Net;
using System.Net.Http;
using AIQuotaBar.Platform.Credentials;
using AIQuotaBar.Providers.Clash;

namespace AIQuotaBar.Cli;

internal static class EnvDoctorCommand
{
    public static int RunEnv(CliOptions options)
    {
        var t0 = CliLog.OpBegin("env");
        ReportEnvironment(options);
        CliLog.Op("env", t0);
        return 0;
    }

    public static async Task<int> RunDoctorAsync(CliOptions options)
    {
        var t0 = CliLog.OpBegin("doctor");
        var failures = 0;

        Console.WriteLine("== [doctor] 环境报告 ==");
        ReportEnvironment(options);

        Console.WriteLine();
        Console.WriteLine("== [doctor] 内置自检 ==");
        failures += SelfTestCommand.Run(options) == 0 ? 0 : 1;

        Console.WriteLine();
        Console.WriteLine("== [doctor] 网络连通 ==");
        // 直连失败只降级为 WARN：部分网络环境（如本项目的远程机）本来就依赖代理，直连不是应用可用性前提。
        _ = await CheckNetworkAsync("直连", null, options).ConfigureAwait(false);
        if (options.Proxy is not null)
        {
            failures += await CheckNetworkAsync($"代理({options.Proxy})", options.Proxy, options).ConfigureAwait(false) ? 0 : 1;
        }
        else
        {
            Console.WriteLine("  [SKIP] 未指定 --proxy（如需经代理测试：aqb doctor --proxy http://<host>:<port>）");
        }

        Console.WriteLine();
        Console.WriteLine("== [doctor] Clash 发现 ==");
        try
        {
            var config = await new ClashConfigurationDiscovery().DiscoverAsync().ConfigureAwait(false);
            Console.WriteLine($"  [PASS] 控制器 {config.BaseUrl}（secret {(string.IsNullOrEmpty(config.Secret) ? "无" : "已配置")}）");
        }
        catch (Exception ex)
        {
            // 本机没有 Clash 属正常形态（WARN 非 FAIL）。
            Console.WriteLine($"  [WARN] 未发现本机 Clash 控制器：{ex.Message}");
        }

        Console.WriteLine();
        Console.WriteLine(failures == 0 ? "doctor 结论：全部通过 ✓" : $"doctor 结论：{failures} 项失败 ✗");
        var code = failures == 0 ? 0 : 1;
        CliLog.Op("doctor", t0);
        return code;
    }

    private static void ReportEnvironment(CliOptions options)
    {
        Console.WriteLine($"  os           : {Environment.OSVersion.VersionString} ({(Environment.Is64BitProcess ? "x64" : "x86")} process)");
        Console.WriteLine($"  runtime      : .NET {Environment.Version}");
        Console.WriteLine($"  user         : {Environment.UserName}@{Environment.MachineName}");
        Console.WriteLine($"  interactive  : {Environment.UserInteractive}");
        Console.WriteLine($"  profile      : {Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)}");
        Console.WriteLine($"  appdata      : {Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData)}");
        Console.WriteLine($"  localappdata : {Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)}");
        var httpProxy = Environment.GetEnvironmentVariable("HTTP_PROXY") ?? Environment.GetEnvironmentVariable("http_proxy");
        var httpsProxy = Environment.GetEnvironmentVariable("HTTPS_PROXY") ?? Environment.GetEnvironmentVariable("https_proxy");
        Console.WriteLine($"  proxy env    : {(httpProxy ?? httpsProxy) ?? "(未设置)"}");
        Console.WriteLine($"  proxy arg    : {options.Proxy ?? "(未指定)"}");
        Console.WriteLine($"  log file     : {CliLog.LogFilePath}");

        var vault = ProbeCredentialVault();
        Console.WriteLine(vault.Writable
            ? "  cred vault   : 可写（交互会话，凭据操作可用）"
            : $"  cred vault   : 不可写（{vault.Reason}）——SSH 网络会话的已知限制，凭据类操作/测试需在交互桌面会话执行（计划 §0）");
        CliLog.Info($"cred-vault writable={vault.Writable} reason={vault.Reason}");
    }

    private static (bool Writable, string Reason) ProbeCredentialVault()
    {
        var service = $"cli-probe-{Guid.NewGuid():N}";
        try
        {
            var store = new CredentialStore();
            store.Write(service, string.Empty, "probe");
            var read = store.Read(service, string.Empty);
            store.Delete(service, string.Empty);
            return read == "probe"
                ? (true, "roundtrip ok")
                : (false, $"roundtrip mismatch（read={read ?? "null"}）");
        }
        catch (Exception ex)
        {
            return (false, ex.Message);
        }
    }

    private static async Task<bool> CheckNetworkAsync(string label, string? proxy, CliOptions options)
    {
        var sw = Stopwatch.StartNew();
        try
        {
            using var http = Support.CreateHttpClient(proxy is null
                ? options with { Proxy = null }
                : options with { Proxy = proxy });
            using var response = await http.GetAsync("https://www.microsoft.com", HttpCompletionOption.ResponseHeadersRead)
                .ConfigureAwait(false);
            Console.WriteLine($"  [{(response.IsSuccessStatusCode ? "PASS" : "FAIL")}] {label}: HTTP {(int)response.StatusCode} in {sw.ElapsedMilliseconds}ms");
            return response.IsSuccessStatusCode;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"  [FAIL] {label}: {ex.Message} ({sw.ElapsedMilliseconds}ms)");
            return false;
        }
    }
}
