// Swift 来源：AIQuotaBar/Services/Clash/ClashAPIClient.swift — enum ClashOpenAIRouteResolver（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashRouteResolverTests.swift

#nullable enable

using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace AIQuotaBar.Providers.Clash;

/// <summary>
/// 从 /rules + /proxies 推断「OpenAI 出口策略组」：优先找指向 Selector 的 OpenAI 规则；
/// 否则按名称排序取第一个疑似 AI 组名（openai/chatgpt/海外ai/人工智能 或独立的 "ai" 词）。
/// </summary>
public static class ClashOpenAIRouteResolver
{
    private static readonly string[] ObservedDomains = { "openai.com", "chatgpt.com" };

    private static readonly Regex LikelyAiNameExpression =
        new("(^|[^a-z])ai([^a-z]|$)", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    public static string? ResolveGroupName(
        IReadOnlyList<ClashRule> rules,
        IReadOnlyDictionary<string, ClashProxy> proxies)
    {
        var selectorNames = proxies
            .Where(pair =>
                string.Equals(pair.Value.Type, "Selector", StringComparison.OrdinalIgnoreCase) &&
                pair.Value.All is { Count: > 0 })
            .Select(pair => pair.Key)
            .ToList();

        foreach (var rule in rules)
        {
            if (IsOpenAIRule(rule) && selectorNames.Contains(rule.Proxy))
            {
                return rule.Proxy;
            }
        }

        return selectorNames
            .OrderBy(name => name, StringComparer.CurrentCultureIgnoreCase)
            .FirstOrDefault(IsLikelyOpenAIGroupName);
    }

    private static bool IsOpenAIRule(ClashRule rule)
    {
        var type = new string(
            rule.Type.ToLowerInvariant().Where(char.IsLetter).ToArray());
        var payload = rule.Payload.Trim().ToLowerInvariant();

        return type switch
        {
            "domain" => payload == "openai.com" || payload == "chatgpt.com",
            "domainsuffix" => ObservedDomains.Any(domain =>
                domain == payload || domain.EndsWith("." + payload, StringComparison.Ordinal)),
            "domainkeyword" => payload.Contains("openai") || payload.Contains("chatgpt"),
            "ruleset" or "geosite" =>
                payload == "ai" ||
                payload.Contains("openai") ||
                payload.Contains("chatgpt") ||
                payload.Contains("category-ai") ||
                payload.Contains("ai-chat"),
            _ => false,
        };
    }

    private static bool IsLikelyOpenAIGroupName(string name)
    {
        var lowercased = name.ToLowerInvariant();
        if (lowercased.Contains("openai") ||
            lowercased.Contains("chatgpt") ||
            lowercased.Contains("海外ai") ||
            lowercased.Contains("人工智能"))
        {
            return true;
        }

        return LikelyAiNameExpression.IsMatch(name);
    }
}
