// Swift 来源：AIQuotaBar/Services/Clash/ClashModels.swift — enum ClashRouteTypeBadge（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashRouteSwitchHistoryStoreTests.swift — testRouteTypeBadgesUseCompactProtocolLabels

#nullable enable

using System;
using System.Linq;

namespace AIQuotaBar.Providers.Clash;

/// <summary>线路协议徽章：识别 Hysteria2/VLESS/AnyTLS 等常见协议并输出紧凑标签，其余取前 3 字符。</summary>
public static class ClashRouteTypeBadge
{
    public static string Text(string type)
    {
        var normalized = new string(
            type.ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray());

        return normalized switch
        {
            "hysteria2" or "hy2" => "H2",
            "hysteria" => "HY",
            "vless" => "VL",
            "vmess" => "VM",
            "anytls" => "TLS",
            "shadowsocks" or "ss" => "SS",
            "trojan" => "TR",
            "wireguard" or "wg" => "WG",
            "tuic" => "TU",
            "snell" => "SN",
            "ssh" => "SSH",
            _ => normalized.Length == 0
                ? "—"
                : normalized[..Math.Min(3, normalized.Length)].ToUpperInvariant(),
        };
    }
}
