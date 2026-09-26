// Swift 来源：无（Windows 端新增；Clash 控制器的完整 CLI 操作）。
// 控制器来源优先级：--url/--secret 显式指定 > ClashConfigurationDiscovery 本机发现。
// 注意：ClashApiClient 仅做 HTTP，不经代理（控制器通常在 loopback——计划 §8 安全边界）。

#nullable enable

using AIQuotaBar.Providers.Clash;

namespace AIQuotaBar.Cli;

internal static class ClashCommand
{
    public static async Task<int> RunAsync(List<string> tail, CliOptions options)
    {
        if (tail.Count == 0)
        {
            throw new UsageException("用法：aqb clash <discover|status|routes|connections|switch|test> [--url <u>] [--secret <s>]");
        }

        var sub = tail[0].ToLowerInvariant();
        var flags = tail.Skip(1).ToList();
        return sub switch
        {
            "discover" => await DiscoverAsync().ConfigureAwait(false),
            "status" => await WithClientAsync(flags, StatusAsync).ConfigureAwait(false),
            "routes" => await WithClientAsync(flags, RoutesAsync).ConfigureAwait(false),
            "connections" => await WithClientAsync(flags, ConnectionsAsync).ConfigureAwait(false),
            "switch" => await SwitchAsync(flags).ConfigureAwait(false),
            "test" => await TestAsync(flags).ConfigureAwait(false),
            _ => throw new UsageException($"未知子命令：clash {sub}（可用：discover/status/routes/connections/switch/test）"),
        };
    }

    private static async Task<int> DiscoverAsync()
    {
        var t0 = CliLog.OpBegin("clash discover");
        var config = await new ClashConfigurationDiscovery().DiscoverAsync().ConfigureAwait(false);
        Console.WriteLine($"  base url  : {config.BaseUrl}");
        Console.WriteLine($"  secret    : {(string.IsNullOrEmpty(config.Secret) ? "(无)" : "已配置")}");
        Console.WriteLine($"  client    : {config.ClientName}");
        Console.WriteLine($"  config url: {config.ConfigUrl}");
        CliLog.Op("clash discover", t0);
        return 0;
    }

    private static async Task<int> WithClientAsync(
        List<string> flags,
        Func<ClashApiClient, Task<int>> action)
    {
        using var client = BuildClient(flags);
        return await action(client).ConfigureAwait(false);
    }

    private static async Task<int> StatusAsync(ClashApiClient client)
    {
        var t0 = CliLog.OpBegin("clash status");
        var version = await client.GetVersionAsync().ConfigureAwait(false);
        Console.WriteLine($"  version : {version.Version} (meta={version.Meta})");
        var snapshot = await client.LoadRouteSnapshotAsync().ConfigureAwait(false);
        Console.WriteLine($"  group   : {snapshot.GroupName}");
        Console.WriteLine($"  selected: {snapshot.SelectedRouteName}（{snapshot.Routes.Count} 条路由）");
        CliLog.Op("clash status", t0);
        return 0;
    }

    private static async Task<int> RoutesAsync(ClashApiClient client)
    {
        var t0 = CliLog.OpBegin("clash routes");
        var snapshot = await client.LoadRouteSnapshotAsync().ConfigureAwait(false);
        Console.WriteLine($"  组 {snapshot.GroupName}，当前 {snapshot.SelectedRouteName}：");
        foreach (var route in snapshot.Routes)
        {
            var mark = route.IsSelected ? "*" : " ";
            var delay = route.Delay is { } d ? (d > 0 ? $"{d}ms" : "timeout") : "-";
            Console.WriteLine($"  {mark} {route.Name,-40} {route.Type,-12} {delay}");
        }

        CliLog.Op("clash routes", t0);
        return 0;
    }

    private static async Task<int> ConnectionsAsync(ClashApiClient client)
    {
        var t0 = CliLog.OpBegin("clash connections");
        var snapshot = await client.LoadConnectionsSnapshotAsync().ConfigureAwait(false);
        Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(snapshot, AIQuotaBar.Core.Contracts.QuotaJson.Default));
        CliLog.Op("clash connections", t0);
        return 0;
    }

    private static async Task<int> SwitchAsync(List<string> flags)
    {
        var positional = flags.Where(f => !f.StartsWith("--", StringComparison.Ordinal)).ToList();
        if (positional.Count < 2)
        {
            throw new UsageException("用法：aqb clash switch <group> <route> [--url <u>] [--secret <s>]");
        }

        var t0 = CliLog.OpBegin("clash switch");
        using var client = BuildClient(flags);
        await client.SelectRouteAsync(routeName: positional[1], groupName: positional[0]).ConfigureAwait(false);
        Console.WriteLine($"  已切换 {positional[0]} → {positional[1]}");
        CliLog.Op("clash switch", t0);
        return 0;
    }

    private static async Task<int> TestAsync(List<string> flags)
    {
        var positional = flags.Where(f => !f.StartsWith("--", StringComparison.Ordinal)).ToList();
        if (positional.Count < 1)
        {
            throw new UsageException("用法：aqb clash test <group> [--url <u>] [--secret <s>]");
        }

        var t0 = CliLog.OpBegin("clash test");
        using var client = BuildClient(flags);
        var results = await client.TestGroupAsync(positional[0]).ConfigureAwait(false);
        foreach (var (name, delay) in results.OrderByDescending(kv => kv.Value))
        {
            Console.WriteLine($"  {name,-40} {(delay > 0 ? $"{delay}ms" : "timeout")}");
        }

        CliLog.Op("clash test", t0);
        return 0;
    }

    private static ClashApiClient BuildClient(List<string> flags)
    {
        var url = TakeOption(flags, "--url");
        var secret = TakeOption(flags, "--secret");
        if (url is not null)
        {
            var normalized = ClashConfigurationDiscovery.ControllerUrl(url);
            return new ClashApiClient(new ClashControllerConfiguration(
                BaseUrl: normalized,
                Secret: secret ?? string.Empty,
                ClientName: "AIQuotaBar.Cli",
                ConfigUrl: new Uri(normalized)));
        }

        // 无显式参数时走本机发现（同步阻塞等待 —— CLI 入口，无 SynchronizationContext）。
        var discovered = new ClashConfigurationDiscovery()
            .DiscoverAsync().GetAwaiter().GetResult();
        if (secret is not null)
        {
            discovered = discovered with { Secret = secret };
        }

        return new ClashApiClient(discovered);
    }

    private static string? TakeOption(List<string> args, string name)
    {
        for (var i = 0; i < args.Count; i++)
        {
            if (args[i] == name && i + 1 < args.Count)
            {
                var value = args[i + 1];
                args.RemoveRange(i, 2);
                return value;
            }
        }

        return null;
    }
}
