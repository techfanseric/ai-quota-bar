using Xunit;

namespace AQB.Providers.Codex.Tests;

/// <summary>chatgpt_base_url in ~/.codex/config.toml overrides the usage endpoint (macOS parity).</summary>
public class ConfigBaseUrlTests
{
    [Fact]
    public async Task TopLevelChatgptBaseUrlOverridesUsageEndpoint()
    {
        using var home = new TempCodexHome();
        File.WriteAllText(
            Path.Combine(home.Root, "config.toml"),
            "model = \"gpt-5\"\nchatgpt_base_url = \"https://codex-proxy.example/v1\"\n");
        var handler = new StubHttpHandler();
        handler.EnqueueJson(UsageResponses.Normal);
        var client = new CodexUsageClient(handler, home.Root);

        await client.FetchAsync(new CodexAuthInfo { AccountId = "org-1", RawJson = AuthFiles.AuthJson() });

        var request = Assert.Single(handler.Requests);
        Assert.Equal("https://codex-proxy.example/v1/backend-api/wham/usage", request.Uri.ToString());
    }

    [Fact]
    public async Task SectionScopedChatgptBaseUrlIsIgnored()
    {
        using var home = new TempCodexHome();
        File.WriteAllText(
            Path.Combine(home.Root, "config.toml"),
            "[mcp_servers.foo]\nchatgpt_base_url = \"https://nope.example\"\n");
        var handler = new StubHttpHandler();
        handler.EnqueueJson(UsageResponses.Normal);
        var client = new CodexUsageClient(handler, home.Root);

        await client.FetchAsync(new CodexAuthInfo { AccountId = "org-1", RawJson = AuthFiles.AuthJson() });

        var request = Assert.Single(handler.Requests);
        Assert.Equal("https://chatgpt.com/backend-api/wham/usage", request.Uri.ToString());
    }

    [Fact]
    public void ReadChatgptBaseUrlMissingFileYieldsNull()
    {
        var missing = Path.Combine(Path.GetTempPath(), "aqb-codex-missing-" + Guid.NewGuid().ToString("N"));

        Assert.Null(CodexPaths.ReadChatgptBaseUrl(missing));
    }

    [Fact]
    public void ExplicitBaseUrlBeatsConfigToml()
    {
        using var home = new TempCodexHome();
        File.WriteAllText(
            Path.Combine(home.Root, "config.toml"),
            "chatgpt_base_url = \"https://from-toml.example\"\n");
        var handler = new StubHttpHandler();
        handler.EnqueueJson(UsageResponses.Normal);
        var client = new CodexUsageClient(handler, home.Root, baseUrl: "https://explicit.example");

        Assert.Equal("https://explicit.example", client.BaseUrl);
    }
}
