namespace AQB.Clash;

/// <summary>Compact protocol badges for route rows, keyed by the alphanumerics of the type.</summary>
public static class ProtocolBadge
{
    /// <summary>Returns the badge text for a proxy type (empty input renders an em dash).</summary>
    public static string Text(string type)
    {
        var normalized = new string(type.ToLowerInvariant()
            .Where(char.IsLetterOrDigit)
            .ToArray());

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
            "" => "—",
            _ => normalized.Length <= 3
                ? normalized.ToUpperInvariant()
                : normalized[..3].ToUpperInvariant(),
        };
    }
}
