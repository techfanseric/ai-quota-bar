// Swift 来源：AIQuotaBar/Services/Clash/ClashConnectionModels.swift — enum ClashOpenAIConnectionFilter（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashConnectionTests.swift — testFilterMatchesOnlyOpenAIAndChatGPTDomainSuffixes 等

#nullable enable

using System;
using System.Linq;

namespace AIQuotaBar.Providers.Clash;

/// <summary>OpenAI 连接固定过滤：host / sniffHost / remoteDestination / rulePayload 任一命中 openai.com|chatgpt.com 后缀。</summary>
public static class ClashOpenAIConnectionFilter
{
    private static readonly string[] ObservedDomains = { "openai.com", "chatgpt.com" };

    public static bool Matches(ClashConnectionRecord connection)
    {
        var metadata = connection.Metadata;
        var candidates = new[]
        {
            metadata.Host,
            metadata.SniffHost,
            metadata.RemoteDestination,
            connection.RulePayload,
        };

        return candidates
            .Any(candidate => candidate is not null && MatchesObservedDomain(candidate));
    }

    public static string DisplayHost(ClashConnectionRecord connection)
    {
        var candidates = new[]
        {
            connection.Metadata.Host,
            connection.Metadata.SniffHost,
            connection.Metadata.RemoteDestination,
        };

        foreach (var candidate in candidates.Where(candidate => candidate is not null))
        {
            var normalized = NormalizedHost(candidate!);
            if (normalized.Length > 0)
            {
                return normalized;
            }
        }

        return connection.Metadata.DestinationIp ?? "—";
    }

    private static bool MatchesObservedDomain(string rawValue)
    {
        var host = NormalizedHost(rawValue);
        return ObservedDomains.Any(domain =>
            host == domain || host.EndsWith("." + domain, StringComparison.Ordinal));
    }

    private static string NormalizedHost(string rawValue)
    {
        var value = rawValue.Trim().ToLowerInvariant();

        // Swift URL(string:)?.host：只有解析出真实 host（带 scheme 的 URL）才采用；
        // "chatgpt.com:443" 这类裸 host:port 在两端的 URL 解析里都取不到 host，走下面的端口剥离。
        if (Uri.TryCreate(value, UriKind.Absolute, out var parsed) &&
            !string.IsNullOrEmpty(parsed.Host))
        {
            value = parsed.Host;
        }

        if (value.StartsWith("+.", StringComparison.Ordinal))
        {
            value = value[2..];
        }
        else if (value.StartsWith('.', StringComparison.Ordinal))
        {
            value = value[1..];
        }

        // 剥离 "host:443" 形式的端口；含 "]"（IPv6 字面量）时不剥。
        var colon = value.LastIndexOf(':');
        if (colon >= 0 &&
            !value.Contains(']') &&
            colon + 1 < value.Length &&
            value[(colon + 1)..].All(char.IsDigit))
        {
            value = value[..colon];
        }

        while (value.EndsWith('.', StringComparison.Ordinal))
        {
            value = value[..^1];
        }

        return value;
    }
}
