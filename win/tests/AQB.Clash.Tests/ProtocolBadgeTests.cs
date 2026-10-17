using Xunit;

namespace AQB.Clash.Tests;

public class ProtocolBadgeTests
{
    [Theory]
    [InlineData("Hysteria2", "H2")]
    [InlineData("hy2", "H2")]
    [InlineData("Hysteria", "HY")]
    [InlineData("VLESS", "VL")]
    [InlineData("VMess", "VM")]
    [InlineData("Trojan", "TR")]
    [InlineData("Shadowsocks", "SS")]
    [InlineData("ss", "SS")]
    [InlineData("AnyTLS", "TLS")]
    [InlineData("WireGuard", "WG")]
    [InlineData("wg", "WG")]
    [InlineData("TUIC", "TU")]
    [InlineData("Snell", "SN")]
    [InlineData("SSH", "SSH")]
    [InlineData("Custom Proxy", "CUS")]
    [InlineData("URLTest", "URL")]
    [InlineData("", "—")]
    public void MapsProtocolTypesToCompactBadges(string type, string expected)
    {
        Assert.Equal(expected, ProtocolBadge.Text(type));
    }
}
