// Swift 来源：AIQuotaBar/Tests/Clash/ClashRouteResolverTests.swift（v1.28.1）

#nullable enable

using System.Collections.Generic;
using System.Linq;
using AIQuotaBar.Providers.Clash;
using Xunit;

namespace AIQuotaBar.Providers.Tests.Clash;

public sealed class ClashRouteResolverTests
{
    [Fact]
    public void ResolvesSelectorFromAIRuleSet()
    {
        var groupName = "[类]-海外AI🤖";
        var proxies = new Dictionary<string, ClashProxy>
        {
            [groupName] = new(
                Name: groupName,
                Type: "Selector",
                Now: "日本 01",
                All: new[] { "日本 01", "新加坡 01" },
                History: null),
            ["日本 01"] = new(
                Name: "日本 01",
                Type: "Vless",
                Now: null,
                All: null,
                History: null),
        };
        var rules = new[]
        {
            new ClashRule(Type: "RuleSet", Payload: "private_domain", Proxy: "DIRECT"),
            new ClashRule(Type: "RuleSet", Payload: "ai", Proxy: groupName),
        };

        Assert.Equal(
            groupName,
            ClashOpenAIRouteResolver.ResolveGroupName(rules, proxies));
    }

    [Fact]
    public void DoesNotMistakePrivateDomainForAIRuleSet()
    {
        var unrelatedGroup = "Manual";
        var proxies = new Dictionary<string, ClashProxy>
        {
            [unrelatedGroup] = new(
                Name: unrelatedGroup,
                Type: "Selector",
                Now: "Node",
                All: new[] { "Node" },
                History: null),
        };
        var rules = new[]
        {
            new ClashRule(Type: "RuleSet", Payload: "private_domain", Proxy: unrelatedGroup),
        };

        // 应然：private_domain 不是 AI 规则，组名 Manual 也不含独立的 "ai" 词。
        Assert.Null(ClashOpenAIRouteResolver.ResolveGroupName(rules, proxies));
    }

    [Fact]
    public void SorterPlacesSuccessfulLowestLatencyFirstAndTimeoutsLast()
    {
        var routes = new[]
        {
            new ClashRoute("timeout", "Vless", 0, IsSelected: false),
            new ClashRoute("slow", "Vless", 210, IsSelected: false),
            new ClashRoute("unknown", "Vless", null, IsSelected: false),
            new ClashRoute("fast", "Vless", 72, IsSelected: true),
        };

        Assert.Equal(
            new[] { "fast", "slow", "timeout", "unknown" },
            ClashRouteSorter.Sorted(routes).Select(route => route.Name).ToArray());
    }
}
