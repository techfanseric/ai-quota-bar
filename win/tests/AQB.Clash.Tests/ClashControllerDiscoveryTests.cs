using Xunit;

namespace AQB.Clash.Tests;

public class ClashControllerDiscoveryTests
{
    private static string TempDir()
    {
        var path = Path.Combine(Path.GetTempPath(), "aqb-clash-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        return path;
    }

    [Fact]
    public void TopLevelYaml_ReadsControllerAndQuotedSecret_IgnoringNestedKeys()
    {
        const string yaml = """
            external-controller: "127.0.0.1:9097"
            secret: 'value # with comment'
            dns:
              secret: nested-value
              external-controller: nested:1234
            mode: rule # active mode
            """;

        var values = TopLevelYaml.Parse(yaml);

        Assert.Equal("127.0.0.1:9097", values["external-controller"]);
        Assert.Equal("value # with comment", values["secret"]);
        Assert.Equal("rule", values["mode"]);
        Assert.Single(values, entry => entry.Key == "secret");
    }

    [Fact]
    public void TopLevelYaml_DecodesSingleQuoteEscapesAndInlineComments()
    {
        const string yaml = """
            secret: 'it''s # fine'
            password: "a\"b"
            plain:  hello world   # trailing comment
            empty:
            """;

        var values = TopLevelYaml.Parse(yaml);

        Assert.Equal("it's # fine", values["secret"]);
        Assert.Equal("a\"b", values["password"]);
        Assert.Equal("hello world", values["plain"]);
        Assert.Equal("", values["empty"]);
    }

    [Theory]
    [InlineData("0.0.0.0:9097", "http://127.0.0.1:9097")]
    [InlineData("*:9097", "http://127.0.0.1:9097")]
    [InlineData("[::]:9097", "http://127.0.0.1:9097")]
    [InlineData(":9097", "http://127.0.0.1:9097")]
    [InlineData("127.0.0.1:9097", "http://127.0.0.1:9097")]
    [InlineData("localhost:9097", "http://localhost:9097")]
    [InlineData("https://localhost:9443", "https://localhost:9443")]
    public void NormalizeControllerUrl_RewritesWildcardBindingsToLoopback(string raw, string expected)
    {
        Assert.True(ClashControllerDiscovery.TryNormalizeControllerUrl(raw, out var baseUrl, out var rejection));
        Assert.Null(rejection);
        Assert.Equal(expected, baseUrl);
    }

    [Fact]
    public void NormalizeControllerUrl_AcceptsIpv6Loopback()
    {
        Assert.True(ClashControllerDiscovery.TryNormalizeControllerUrl("[::1]:9097", out var baseUrl, out _));
        Assert.Equal("http://[::1]:9097", baseUrl);
    }

    [Fact]
    public void NormalizeControllerUrl_RejectsNonLoopbackHosts()
    {
        Assert.False(ClashControllerDiscovery.TryNormalizeControllerUrl("192.168.1.2:9097", out _, out var rejection));
        Assert.StartsWith(ClashDiscoveryReasons.UnsafeControllerHost, rejection);
        Assert.Contains("192.168.1.2", rejection);
    }

    [Theory]
    [InlineData("192.168.1.2:9097")]
    [InlineData("example.com:9097")]
    public void NormalizeControllerUrl_RejectsRemoteHosts(string raw)
    {
        Assert.False(ClashControllerDiscovery.TryNormalizeControllerUrl(raw, out _, out var rejection));
        Assert.StartsWith(ClashDiscoveryReasons.UnsafeControllerHost, rejection);
    }

    [Theory]
    [InlineData("127.0.0.1:notaport")]
    [InlineData("127.0.0.1:0")]
    [InlineData("http://127.0.0.1:99999")]
    public void NormalizeControllerUrl_RejectsInvalidAddresses(string raw)
    {
        Assert.False(ClashControllerDiscovery.TryNormalizeControllerUrl(raw, out _, out var rejection));
        Assert.StartsWith(ClashDiscoveryReasons.InvalidControllerAddress, rejection);
    }

    [Fact]
    public void CandidatePaths_PutWindowsVergeConfigFirst()
    {
        var candidates = ClashControllerDiscovery.GetCandidateConfigPaths(
            appDataDirectory: @"C:\fake\appdata",
            homeDirectory: @"C:\fake\home");

        Assert.Equal(3, candidates.Count);
        Assert.Equal(
            @"C:\fake\appdata\io.github.clash-verge-rev.clash-verge-rev\config.yaml",
            candidates[0].Path);
        Assert.Equal("Clash Verge Rev", candidates[0].ClientName);
        Assert.Equal(@"C:\fake\home\.config\mihomo\config.yaml", candidates[1].Path);
        Assert.Equal("Mihomo", candidates[1].ClientName);
        Assert.Equal(@"C:\fake\home\.config\clash\config.yaml", candidates[2].Path);
        Assert.Equal("Clash", candidates[2].ClientName);
    }

    [Fact]
    public void FindEndpoint_DiscoversVergeRuntimeConfiguration()
    {
        var appData = TempDir();
        var configDir = Path.Combine(appData, "io.github.clash-verge-rev.clash-verge-rev");
        Directory.CreateDirectory(configDir);
        File.WriteAllText(
            Path.Combine(configDir, "config.yaml"),
            "external-controller: 127.0.0.1:9097\nsecret: \"test-secret\"\n");

        try
        {
            var endpoint = ClashControllerDiscovery.FindEndpoint(appDataDirectory: appData, homeDirectory: appData);

            Assert.NotNull(endpoint);
            Assert.True(endpoint.IsUsable);
            Assert.Equal("http://127.0.0.1:9097", endpoint.BaseUrl);
            Assert.Equal("test-secret", endpoint.Secret);
            Assert.Equal("Clash Verge Rev", endpoint.ClientName);
            Assert.Equal(Path.Combine(configDir, "config.yaml"), endpoint.SourceConfigPath);
        }
        finally
        {
            Directory.Delete(appData, true);
        }
    }

    [Fact]
    public void FindEndpoint_FallsThroughToMihomoWhenVergeLacksController()
    {
        var appData = TempDir();
        var home = TempDir();
        Directory.CreateDirectory(Path.Combine(appData, "io.github.clash-verge-rev.clash-verge-rev"));
        File.WriteAllText(
            Path.Combine(appData, "io.github.clash-verge-rev.clash-verge-rev", "config.yaml"),
            "mode: rule\n");
        var mihomoDir = Path.Combine(home, ".config", "mihomo");
        Directory.CreateDirectory(mihomoDir);
        File.WriteAllText(
            Path.Combine(mihomoDir, "config.yaml"),
            "external-controller: '0.0.0.0:9097'\n");

        try
        {
            var endpoint = ClashControllerDiscovery.FindEndpoint(appDataDirectory: appData, homeDirectory: home);

            Assert.NotNull(endpoint);
            Assert.True(endpoint.IsUsable);
            Assert.Equal("http://127.0.0.1:9097", endpoint.BaseUrl);
            Assert.Equal("Mihomo", endpoint.ClientName);
        }
        finally
        {
            Directory.Delete(appData, true);
            Directory.Delete(home, true);
        }
    }

    [Fact]
    public void FindEndpoint_ReportsExternalControllerDisabledWhenKeyMissing()
    {
        var appData = TempDir();
        Directory.CreateDirectory(Path.Combine(appData, ".config", "clash"));
        File.WriteAllText(
            Path.Combine(appData, ".config", "clash", "config.yaml"),
            "port: 7890\n");

        try
        {
            var endpoint = ClashControllerDiscovery.FindEndpoint(appDataDirectory: appData, homeDirectory: appData);

            Assert.NotNull(endpoint);
            Assert.False(endpoint.IsUsable);
            Assert.Equal(ClashDiscoveryReasons.ExternalControllerDisabled, endpoint.DisabledReason);
        }
        finally
        {
            Directory.Delete(appData, true);
        }
    }

    [Fact]
    public void FindEndpoint_ReportsConfigurationNotFoundWhenNoCandidatesExist()
    {
        var appData = TempDir();
        var home = TempDir();
        try
        {
            var endpoint = ClashControllerDiscovery.FindEndpoint(appDataDirectory: appData, homeDirectory: home);

            Assert.NotNull(endpoint);
            Assert.False(endpoint.IsUsable);
            Assert.Equal(ClashDiscoveryReasons.ConfigurationNotFound, endpoint.DisabledReason);
        }
        finally
        {
            Directory.Delete(appData, true);
            Directory.Delete(home, true);
        }
    }

    [Fact]
    public void FindEndpoint_RejectsUnsafeHostInExistingConfig()
    {
        var appData = TempDir();
        var configDir = Path.Combine(appData, "io.github.clash-verge-rev.clash-verge-rev");
        Directory.CreateDirectory(configDir);
        File.WriteAllText(
            Path.Combine(configDir, "config.yaml"),
            "external-controller: 192.168.1.2:9097\n");

        try
        {
            var endpoint = ClashControllerDiscovery.FindEndpoint(appDataDirectory: appData, homeDirectory: appData);

            Assert.NotNull(endpoint);
            Assert.False(endpoint.IsUsable);
            Assert.StartsWith(ClashDiscoveryReasons.UnsafeControllerHost, endpoint.DisabledReason);
        }
        finally
        {
            Directory.Delete(appData, true);
        }
    }
}
