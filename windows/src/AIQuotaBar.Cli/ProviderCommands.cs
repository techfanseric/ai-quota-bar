// Swift 来源：无（Windows 端新增；GLM / MiniMax 配额直查与连通性测试）。
// 凭据解析：--credential 直传（GLM 支持 API key / cURL 导入 / 存储 JSON 三形态，
// 见 GlmCredentialParser）；--credential-file 从文件读；--from-cred-store 从本机
// Credential Manager 取（service=glm/minimax，account 默认空）。

#nullable enable

using AIQuotaBar.Platform.Credentials;
using AIQuotaBar.Providers.Glm;
using AIQuotaBar.Providers.Minimax;

namespace AIQuotaBar.Cli;

internal static class ProviderCommand
{
    public static async Task<int> RunGlmAsync(List<string> tail, CliOptions options)
    {
        if (tail.Count == 0)
        {
            throw new UsageException("用法：aqb glm <quota|test> --credential <c> | --credential-file <p> | --from-cred-store [--account <a>]");
        }

        var sub = tail[0].ToLowerInvariant();
        var credential = ResolveCredential(tail.Skip(1).ToList(), service: "glm");
        using var http = Support.CreateHttpClient(options);
        var client = new GlmClient(http);
        var t0 = CliLog.OpBegin($"glm {sub}");
        if (sub == "test")
        {
            var ok = await client.TestConnectionAsync(credential).ConfigureAwait(false);
            Console.WriteLine(ok ? "[PASS] GLM 连通性测试通过" : "[FAIL] GLM 连通性测试未通过");
            CliLog.Op($"glm {sub}", t0);
            return ok ? 0 : 1;
        }

        if (sub != "quota")
        {
            throw new UsageException($"未知子命令：glm {sub}（可用：quota/test）");
        }

        var usage = await client.FetchUsageAsync(credential).ConfigureAwait(false);
        Support.PrintUsage(usage, options);
        CliLog.Op($"glm {sub}", t0);
        return 0;
    }

    public static async Task<int> RunMinimaxAsync(List<string> tail, CliOptions options)
    {
        if (tail.Count == 0)
        {
            throw new UsageException("用法：aqb minimax <quota|test> --token <t> | --from-cred-store [--region global|cn] [--group <g>]");
        }

        var sub = tail[0].ToLowerInvariant();
        var flags = tail.Skip(1).ToList();
        var region = ParseRegion(ExtractOptionValue(flags, "--region"));
        var group = ExtractOptionValue(flags, "--group");
        var token = flags.Contains("--from-cred-store")
            ? ReadFromStore("minimax", ExtractOptionValue(flags, "--account") ?? string.Empty)
            : ExtractOptionValue(flags, "--token")
              ?? throw new UsageException("缺少 --token（或用 --from-cred-store）");

        using var http = Support.CreateHttpClient(options);
        var client = new MinimaxClient(http, region);
        var t0 = CliLog.OpBegin($"minimax {sub}");
        if (sub == "test")
        {
            var ok = await client.TestConnectionAsync(token).ConfigureAwait(false);
            Console.WriteLine(ok ? "[PASS] MiniMax 连通性测试通过" : "[FAIL] MiniMax 连通性测试未通过");
            CliLog.Op($"minimax {sub}", t0);
            return ok ? 0 : 1;
        }

        if (sub != "quota")
        {
            throw new UsageException($"未知子命令：minimax {sub}（可用：quota/test）");
        }

        var usage = await client.FetchUsageAsync(token, group).ConfigureAwait(false);
        Support.PrintUsage(usage, options);
        CliLog.Op($"minimax {sub}", t0);
        return 0;
    }

    private static string ResolveCredential(List<string> flags, string service)
    {
        if (flags.Contains("--from-cred-store"))
        {
            return ReadFromStore(service, ExtractOptionValue(flags, "--account") ?? string.Empty);
        }

        var inline = ExtractOptionValue(flags, "--credential");
        if (inline is not null)
        {
            return inline;
        }

        var path = ExtractOptionValue(flags, "--credential-file");
        if (path is not null)
        {
            return File.ReadAllText(path).Trim();
        }

        throw new UsageException($"缺少凭据：--credential <c> / --credential-file <p> / --from-cred-store");
    }

    private static string ReadFromStore(string service, string account)
    {
        var secret = new CredentialStore().Read(service, account);
        return secret ?? throw new InvalidOperationException(
            $"Credential Manager 中没有 {service}:{account}（先 aqb cred write {service} '{account}' --stdin）");
    }

    private static MinimaxApiRegion ParseRegion(string? raw) => raw switch
    {
        null or "global" => MinimaxApiRegion.Global,
        "cn" => MinimaxApiRegion.ChinaMainland,
        _ => throw new UsageException($"未知 --region：{raw}（可用：global|cn）"),
    };

    private static string? ExtractOptionValue(List<string> args, string name)
    {
        for (var i = 0; i < args.Count; i++)
        {
            if (args[i] == name && i + 1 < args.Count && !args[i + 1].StartsWith("--", StringComparison.Ordinal))
            {
                var value = args[i + 1];
                args.RemoveRange(i, 2);
                return value;
            }
        }

        return null;
    }
}
