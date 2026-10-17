using Xunit;

namespace AQB.Clash.Tests;

public class ClashRouteResolverTests
{
    private static ClashProxy Selector(string name, string? now, params string[] all)
        => new() { Name = name, Type = "Selector", Now = now, All = all };

    private static ClashRule Rule(string type, string payload, string proxy)
        => new() { Type = type, Payload = payload, Proxy = proxy };

    [Fact]
    public void ResolvesSelectorFromAiRuleSet()
    {
        const string groupName = "[类]-海外AI🤖";
        var proxies = new Dictionary<string, ClashProxy>
        {
            [groupName] = Selector(groupName, "日本 01", "日本 01", "新加坡 01"),
            ["日本 01"] = new() { Name = "日本 01", Type = "Vless" },
        };
        var rules = new[]
        {
            Rule("RuleSet", "private_domain", "DIRECT"),
            Rule("RuleSet", "ai", groupName),
        };

        Assert.Equal(groupName, ClashRouteResolver.ResolveGroupName(rules, proxies));
    }

    [Fact]
    public void DoesNotMistakePrivateDomainForAiRuleSet()
    {
        var proxies = new Dictionary<string, ClashProxy>
        {
            ["Manual"] = Selector("Manual", "Node", "Node"),
        };
        var rules = new[] { Rule("RuleSet", "private_domain", "Manual") };

        Assert.Null(ClashRouteResolver.ResolveGroupName(rules, proxies));
    }

    [Fact]
    public void UrlTestGroupsAreNotCandidates()
    {
        var proxies = new Dictionary<string, ClashProxy>
        {
            ["Auto"] = new() { Name = "Auto", Type = "URLTest", Now = "Node", All = new[] { "Node" } },
        };
        var rules = new[] { Rule("RuleSet", "ai", "Auto") };

        Assert.Null(ClashRouteResolver.ResolveGroupName(rules, proxies));
    }

    [Theory]
    [InlineData("Domain", "openai.com")]
    [InlineData("DomainSuffix", "openai.com")]
    [InlineData("DomainSuffix", "chatgpt.com")]
    [InlineData("DomainSuffix", "com")]
    [InlineData("DomainKeyword", "openai")]
    [InlineData("RuleSet", "category-ai-!cn")]
    [InlineData("GeoSite", "ai-chat")]
    [InlineData("RULE-SET", "AI")]
    public void RecognizesOpenAiRules(string type, string payload)
    {
        Assert.True(ClashRouteResolver.IsOpenAiRule(Rule(type, payload, "AI")));
    }

    [Theory]
    [InlineData("Domain", "oaistatic.com")]
    [InlineData("DomainSuffix", "openai.example")]
    [InlineData("DomainKeyword", "static")]
    [InlineData("RuleSet", "private_domain")]
    [InlineData("GeoSite", "private")]
    [InlineData("IpCidr", "openai.com/24")]
    [InlineData("Match", "")]
    public void RejectsNonOpenAiRules(string type, string payload)
    {
        Assert.False(ClashRouteResolver.IsOpenAiRule(Rule(type, payload, "AI")));
    }

    [Fact]
    public void RuleTargetMustBeAnExistingSelector()
    {
        var proxies = new Dictionary<string, ClashProxy>
        {
            ["Real"] = Selector("Real", "Node", "Node"),
        };
        var rules = new[]
        {
            Rule("RuleSet", "ai", "Missing"),
            Rule("DomainSuffix", "openai.com", "Real"),
        };

        Assert.Equal("Real", ClashRouteResolver.ResolveGroupName(rules, proxies));
    }

    [Fact]
    public void NameFallbackMatchesOpenAiKeywordsAndStandaloneAi()
    {
        foreach (var name in new[] { "ChatGPT 路线", "openai premium", "[类]-海外AI🤖", "人工智能优选", "AI 手选" })
        {
            var proxies = new Dictionary<string, ClashProxy>
            {
                [name] = Selector(name, "Node", "Node"),
            };
            Assert.Equal(name, ClashRouteResolver.ResolveGroupName(Array.Empty<ClashRule>(), proxies));
        }
    }

    [Fact]
    public void NameFallbackIgnoresNonAiGroups()
    {
        var proxies = new Dictionary<string, ClashProxy>
        {
            ["Streaming"] = Selector("Streaming", "Node", "Node"),
            ["Direct"] = Selector("Direct", "Node", "Node"),
        };

        Assert.Null(ClashRouteResolver.ResolveGroupName(Array.Empty<ClashRule>(), proxies));
    }

    [Fact]
    public void NameFallbackPicksStableOrderWinner()
    {
        var proxies = new Dictionary<string, ClashProxy>
        {
            ["B AI"] = Selector("B AI", "Node", "Node"),
            ["A ChatGPT"] = Selector("A ChatGPT", "Node", "Node"),
        };

        Assert.Equal("A ChatGPT", ClashRouteResolver.ResolveGroupName(Array.Empty<ClashRule>(), proxies));
    }

    [Fact]
    public void BuildRoutes_MapsMembersWithHistoryAndSelection()
    {
        var group = Selector("AI", "JP 01", "JP 01", "US 01", "Ghost");
        var proxies = new Dictionary<string, ClashProxy>
        {
            ["AI"] = group,
            ["JP 01"] = new()
            {
                Name = "JP 01",
                Type = "Vless",
                History = new[] { new ClashProxyHistory { Time = "t1", Delay = 120 }, new() { Time = "t2", Delay = 82 } },
            },
            ["US 01"] = new() { Name = "US 01", Type = "Trojan", History = new[] { new ClashProxyHistory { Delay = 0 } } },
        };

        var routes = ClashRouteResolver.BuildRoutes(group, proxies);

        Assert.Equal(3, routes.Count);
        Assert.Equal("JP 01", routes[0].Name);
        Assert.Equal("Vless", routes[0].Type);
        Assert.Equal(82, routes[0].Delay);
        Assert.True(routes[0].IsSelected);
        Assert.Equal(0, routes[1].Delay);
        Assert.False(routes[1].IsSelected);
        Assert.Equal("Ghost", routes[2].Name);
        Assert.Equal("Unknown", routes[2].Type);
        Assert.Null(routes[2].Delay);
    }

    [Fact]
    public void ApplyDelays_MarksMissingNodesAsTimedOutAndSorts()
    {
        var routes = new List<ClashRoute>
        {
            new() { Name = "timeout", Type = "Vless", Delay = 500 },
            new() { Name = "fast", Type = "Vless", Delay = null },
            new() { Name = "slow", Type = "Vless", Delay = 999 },
        };
        var delays = new Dictionary<string, int> { ["fast"] = 72, ["slow"] = 210 };

        var sorted = ClashRouteResolver.ApplyDelays(routes, delays);

        Assert.Equal(new[] { "fast", "slow", "timeout" }, sorted.Select(route => route.Name).ToArray());
        Assert.Equal(0, sorted[2].Delay);
    }

    [Fact]
    public void SorterPlacesUsableLatencyFirstAndTimeoutsLast()
    {
        var routes = new[]
        {
            new ClashRoute { Name = "timeout", Type = "Vless", Delay = 0 },
            new ClashRoute { Name = "slow", Type = "Vless", Delay = 210 },
            new ClashRoute { Name = "unknown", Type = "Vless", Delay = null },
            new ClashRoute { Name = "fast", Type = "Vless", Delay = 72, IsSelected = true },
        };

        Assert.Equal(
            new[] { "fast", "slow", "timeout", "unknown" },
            RouteSorter.Sort(routes).Select(route => route.Name).ToArray());
    }

    [Fact]
    public void SorterBreaksDelayTiesByName()
    {
        var routes = new[]
        {
            new ClashRoute { Name = "b-node", Delay = 100 },
            new ClashRoute { Name = "a-node", Delay = 100 },
            new ClashRoute { Name = "c-node", Delay = 50 },
        };

        Assert.Equal(
            new[] { "c-node", "a-node", "b-node" },
            RouteSorter.Sort(routes).Select(route => route.Name).ToArray());
    }

    [Fact]
    public void SorterOrdersNumbersNaturallyForUnusableRoutes()
    {
        var routes = new[]
        {
            new ClashRoute { Name = "Node 10", Delay = 0 },
            new ClashRoute { Name = "Node 2", Delay = 0 },
        };

        Assert.Equal(
            new[] { "Node 2", "Node 10" },
            RouteSorter.Sort(routes).Select(route => route.Name).ToArray());
    }
}
