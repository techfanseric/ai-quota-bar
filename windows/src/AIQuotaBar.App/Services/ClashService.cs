// Swift 来源：Services/Clash* 面板数据链（Windows 端收敛为单服务）。
// 职责：ClashConfigurationDiscovery 找控制器 → ClashApiClient 供路由面板
// （组/路由/切换/测速/连接概览）。控制器仅 loopback 的安全边界由发现逻辑保证（计划 §8）。

using System.Net.Http;
using AIQuotaBar.Providers.Clash;

namespace AIQuotaBar.App.Services;

public sealed class ClashService
{
    private readonly AppSettings _settings;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public string? Error { get; private set; }

    public ClashService(AppSettings settings) => _settings = settings;

    public async Task<ClashRouteSnapshot?> LoadRoutesAsync()
    {
        var result = await RunAsync(async client =>
        {
            var snapshot = await client.LoadRouteSnapshotAsync().ConfigureAwait(false);
            return snapshot;
        }).ConfigureAwait(false);
        return result;
    }

    public async Task<bool> SwitchRouteAsync(string routeName)
    {
        var snapshot = await LoadRoutesAsync().ConfigureAwait(false);
        if (snapshot is null)
        {
            return false;
        }

        var ok = await RunAsync(async client =>
        {
            await client.SelectRouteAsync(routeName, snapshot.GroupName).ConfigureAwait(false);
            return true;
        }).ConfigureAwait(false);
        return ok == true;
    }

    public async Task<IReadOnlyDictionary<string, int>?> TestGroupAsync(string groupName)
    {
        return await RunAsync(async client => await client.TestGroupAsync(groupName).ConfigureAwait(false)).ConfigureAwait(false);
    }

    private async Task<T?> RunAsync<T>(Func<ClashApiClient, Task<T>> action)
    {
        if (!await _gate.WaitAsync(0).ConfigureAwait(false))
        {
            return default; // 上一个请求未返回：面板层自行重试
        }

        try
        {
            var config = await new ClashConfigurationDiscovery().DiscoverAsync().ConfigureAwait(false);
            using var client = new ClashApiClient(config, _settings.CreateHttpHandler());
            Error = null;
            return await action(client).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            Error = ex.Message;
            return default;
        }
        finally
        {
            _gate.Release();
        }
    }
}
