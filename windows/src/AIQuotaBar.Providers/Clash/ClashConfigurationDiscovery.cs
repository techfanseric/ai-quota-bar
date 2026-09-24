// Swift 来源：AIQuotaBar/Services/Clash/ClashConfigurationDiscovery.swift — struct ClashConfigurationDiscovery（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashConfigurationDiscoveryTests.swift
// fixtures：windows/contracts/fixtures/clash/clash-verge-config.yaml
//
// Windows 路径语义（相对 Swift 的差异，发现逻辑结构不变）：
// - Clash Verge Rev 数据目录：macOS 为 ~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev，
//   Windows 为 %APPDATA%\io.github.clash-verge-rev.clash-verge-rev（另保留 %APPDATA%\clash-verge-rev 变体）；
// - Mihomo / Clash 仍走 %USERPROFILE%\.config\{mihomo,clash}\config.yaml。

#nullable enable

using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace AIQuotaBar.Providers.Clash;

/// <summary>按候选顺序发现本机 Clash 配置并解析出控制器连接参数。</summary>
public sealed class ClashConfigurationDiscovery
{
    private readonly IClashEnvironment _environment;

    public ClashConfigurationDiscovery(IClashEnvironment? environment = null)
    {
        _environment = environment ?? ClashEnvironment.Instance;
    }

    public async Task<ClashControllerConfiguration> DiscoverAsync(CancellationToken cancellationToken = default)
    {
        var foundConfiguration = false;

        foreach (var candidate in CandidateConfigurations())
        {
            if (!File.Exists(candidate.Path))
            {
                continue;
            }

            foundConfiguration = true;

            string contents;
            try
            {
                contents = await File.ReadAllTextAsync(candidate.Path, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                continue;
            }

            var values = ClashTopLevelYaml.Parse(contents);
            if (values.TryGetValue("external-controller", out var rawController) &&
                rawController.Trim().Length > 0)
            {
                var baseUrl = ControllerUrl(rawController);
                return new ClashControllerConfiguration(
                    BaseUrl: baseUrl,
                    Secret: values.TryGetValue("secret", out var secret) ? secret : string.Empty,
                    ClientName: candidate.ClientName,
                    ConfigUrl: new Uri(candidate.Path));
            }
        }

        if (foundConfiguration)
        {
            throw new ClashIntegrationException(new ClashIntegrationError.ExternalControllerDisabled());
        }

        throw new ClashIntegrationException(new ClashIntegrationError.ConfigurationNotFound());
    }

    private IReadOnlyList<CandidateConfiguration> CandidateConfigurations()
    {
        return new[]
        {
            new CandidateConfiguration(
                Path.Combine(
                    _environment.AppData,
                    "io.github.clash-verge-rev.clash-verge-rev",
                    "clash-verge.yaml"),
                "Clash Verge Rev"),
            new CandidateConfiguration(
                Path.Combine(_environment.AppData, "clash-verge-rev", "clash-verge.yaml"),
                "Clash Verge Rev"),
            new CandidateConfiguration(
                Path.Combine(_environment.Home, ".config", "mihomo", "config.yaml"),
                "Mihomo"),
            new CandidateConfiguration(
                Path.Combine(_environment.Home, ".config", "clash", "config.yaml"),
                "Clash"),
        };
    }

    /// <summary>
    /// 归一化 external-controller 地址并强制**仅回环**安全校验：
    /// ":9097" / "*:9097" / "0.0.0.0:9097" / "[::]:9097" 统一归一为 127.0.0.1，
    /// 无 scheme 时补 http://；主机必须是 127.0.0.1 / localhost / ::1 且端口显式存在，
    /// 否则抛 UnsafeControllerHost / InvalidControllerAddress。
    /// 产出为 Swift URL.absoluteString 字符串形态（scheme://host:port，无尾斜杠；
    /// .NET Uri 对 authority-only URI 会规范出尾斜杠，故不走 ToString/AbsoluteUri）。
    /// </summary>
    public static string ControllerUrl(string rawAddress)
    {
        var address = rawAddress.Trim();
        if (address.StartsWith(":", StringComparison.Ordinal))
        {
            address = "127.0.0.1" + address;
        }
        else if (address.StartsWith("*:", StringComparison.Ordinal))
        {
            address = "127.0.0.1:" + address[2..];
        }
        else if (address.StartsWith("0.0.0.0:", StringComparison.Ordinal))
        {
            address = "127.0.0.1:" + address["0.0.0.0:".Length..];
        }
        else if (address.StartsWith("[::]:", StringComparison.Ordinal))
        {
            address = "127.0.0.1:" + address["[::]:".Length..];
        }

        if (!address.Contains("://", StringComparison.Ordinal))
        {
            address = "http://" + address;
        }

        if (!Uri.TryCreate(address, UriKind.Absolute, out var uri) ||
            string.IsNullOrEmpty(uri.Host) ||
            uri.IsDefaultPort)
        {
            throw new ClashIntegrationException(
                new ClashIntegrationError.InvalidControllerAddress(rawAddress));
        }

        var host = uri.Host.ToLowerInvariant();
        if (host is not ("127.0.0.1" or "localhost" or "::1"))
        {
            throw new ClashIntegrationException(new ClashIntegrationError.UnsafeControllerHost(host));
        }

        // SchemeAndServer 恒不携带路径 → authority-only 地址无尾斜杠（与 Swift absoluteString 一致）；
        // 显式携带路径前缀的控制器地址保留路径（GetComponents 的 Path 分量为转义后的原始形态）。
        var server = uri.GetComponents(UriComponents.SchemeAndServer, UriFormat.UriEscaped);
        var path = uri.AbsolutePath;
        return path is "/" or "" ? server : server + path;
    }

    private sealed record CandidateConfiguration(string Path, string ClientName);
}
