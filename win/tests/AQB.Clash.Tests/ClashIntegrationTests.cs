using Xunit;

namespace AQB.Clash.Tests;

/// <summary>
/// Real-controller integration. Discovery runs first; when this machine exposes no usable
/// endpoint the test is skipped (returns) so CI without Clash stays green. On the dev machine
/// Clash Verge Rev listens on 127.0.0.1:9097 with the secret from %APPDATA% config.
/// </summary>
public class ClashIntegrationTests
{
    [Fact]
    public async Task GetVersionAgainstRealControllerWhenDiscovered()
    {
        var endpoint = ClashControllerDiscovery.FindEndpoint();
        if (endpoint is null || !endpoint.IsUsable)
        {
            // No supported Clash configuration on this machine: skip.
            return;
        }

        Assert.StartsWith("http://", endpoint.BaseUrl);
        Assert.Contains(
            new[] { "http://127.0.0.1:", "http://localhost:", "http://[::1]:" },
            prefix => endpoint.BaseUrl.StartsWith(prefix, StringComparison.Ordinal));
        Assert.NotNull(endpoint.Secret);

        using var client = new ClashClient(endpoint);
        var version = await client.GetVersionAsync();

        Assert.False(string.IsNullOrWhiteSpace(version.Version));
    }

    [Fact]
    public async Task ProxiesAndRulesAgainstRealControllerWhenDiscovered()
    {
        var endpoint = ClashControllerDiscovery.FindEndpoint();
        if (endpoint is null || !endpoint.IsUsable)
        {
            return;
        }

        using var client = new ClashClient(endpoint);
        var proxies = await client.GetProxiesAsync();
        var rules = await client.GetRulesAsync();

        Assert.NotEmpty(proxies);
        Assert.NotEmpty(rules);

        // Every entry point the route resolver needs is present in a live payload.
        var groupName = ClashRouteResolver.ResolveGroupName(rules, proxies);
        if (groupName is not null)
        {
            Assert.True(proxies[groupName].All is { Count: > 0 });
            var routes = ClashRouteResolver.BuildRoutes(proxies[groupName], proxies);
            Assert.NotEmpty(routes);
        }
    }
}
