// Swift 来源：AIQuotaBar/Tests/Clash/ClashConfigurationDiscoveryTests.swift（v1.28.1）
// Windows 语义差异：候选路径改为 %APPDATA%\io.github.clash-verge-rev.clash-verge-rev 等
//（见 ClashConfigurationDiscovery.cs 文件头），测试经 IClashEnvironment 桩注入临时根。
// fixtures：clash-verge-config.yaml（发现测试的配置文件内容）。
// 说明：testTopLevelYAML… 的多行 YAML 是被测解析器的单元输入（非 API 响应），
// 与 Swift 端一致就地内联；真实配置文件样本走 fixture。

#nullable enable

using System;
using System.IO;
using System.Threading.Tasks;
using AIQuotaBar.Providers.Clash;
using Xunit;

namespace AIQuotaBar.Providers.Tests.Clash;

public sealed class ClashConfigurationDiscoveryTests
{
    [Fact]
    public void TopLevelYamlReadsControllerAndQuotedSecretWithoutNestedKeys()
    {
        var contents = string.Join('\n',
            "external-controller: \"127.0.0.1:9097\"",
            "secret: 'value # with comment'",
            "dns:",
            "  secret: nested-value",
            "mode: rule # active mode");

        var values = ClashTopLevelYaml.Parse(contents);

        // 应然：只读顶层键，嵌套 dns.secret 被忽略；单/双引号与行内注释各自正确解码。
        Assert.Equal("127.0.0.1:9097", values["external-controller"]);
        Assert.Equal("value # with comment", values["secret"]);
        Assert.Equal("rule", values["mode"]);
    }

    [Fact]
    public void ControllerUrlNormalizesWildcardBindingToLoopback()
    {
        var url = ClashConfigurationDiscovery.ControllerUrl("0.0.0.0:9097");

        Assert.Equal("http://127.0.0.1:9097", url.ToString());
    }

    [Fact]
    public void ControllerUrlRejectsRemoteHosts()
    {
        var exception = Assert.Throws<ClashIntegrationException>(
            () => ClashConfigurationDiscovery.ControllerUrl("192.168.1.2:9097"));

        // 应然：非回环主机被拒绝并携带主机名（实然：其他错误或无主机名即失败）。
        Assert.Equal(new ClashIntegrationError.UnsafeControllerHost("192.168.1.2"), exception.Error);
    }

    [Fact]
    public async Task DiscoversClashVergeRuntimeConfiguration()
    {
        var temporaryRoot = Path.Combine(Path.GetTempPath(), "clash-discovery-" + Guid.NewGuid().ToString("N"));
        var configDirectory = Path.Combine(
            temporaryRoot,
            "appdata",
            "io.github.clash-verge-rev.clash-verge-rev");
        Directory.CreateDirectory(configDirectory);
        try
        {
            var configPath = Path.Combine(configDirectory, "clash-verge.yaml");
            await File.WriteAllTextAsync(configPath, Fixtures.ReadClashFixture("clash-verge-config.yaml"));

            var environment = new StubEnvironment(
                Home: Path.Combine(temporaryRoot, "home"),
                AppData: Path.Combine(temporaryRoot, "appdata"));
            var discovery = new ClashConfigurationDiscovery(environment);
            var configuration = await discovery.DiscoverAsync();

            // 应然：命中 %APPDATA% 下的 Verge Rev 配置，解析出回环控制器与 secret。
            Assert.Equal("http://127.0.0.1:9097", configuration.BaseUrl.ToString());
            Assert.Equal("test-secret", configuration.Secret);
            Assert.Equal("Clash Verge Rev", configuration.ClientName);
            Assert.Equal(configPath, configuration.ConfigUrl.LocalPath);
        }
        finally
        {
            TryDeleteDirectory(temporaryRoot);
        }
    }

    [Fact]
    public async Task DiscoverAsyncThrowsWhenNoConfigurationExists()
    {
        var environment = new StubEnvironment(
            Home: Path.Combine(Path.GetTempPath(), "clash-empty-" + Guid.NewGuid().ToString("N")),
            AppData: Path.Combine(Path.GetTempPath(), "clash-empty-appdata-" + Guid.NewGuid().ToString("N")));
        var discovery = new ClashConfigurationDiscovery(environment);

        // 应然：任何候选都不存在 → configurationNotFound（实然不符即失败）。
        var exception = await Assert.ThrowsAsync<ClashIntegrationException>(
            () => discovery.DiscoverAsync());
        Assert.Equal(new ClashIntegrationError.ConfigurationNotFound(), exception.Error);
    }

    private sealed record StubEnvironment(string Home, string AppData) : IClashEnvironment;

    private static void TryDeleteDirectory(string directory)
    {
        try
        {
            if (Directory.Exists(directory))
            {
                Directory.Delete(directory, recursive: true);
            }
        }
        catch (IOException)
        {
            // 清理失败不影响断言。
        }
    }
}
