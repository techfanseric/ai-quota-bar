// Swift 来源：AIQuotaBar/Tests/Clash/ClashRouteFilterTests.swift（v1.28.1）
// 暂缓项：testFilterEditingStartsReadOnlyAndRequiresExplicitEntry（依赖 ClashRouteViewModel，
// UI 层暂缓，见移植报告）。

#nullable enable

using System.Collections.Generic;
using System.Linq;
using AIQuotaBar.Providers.Clash;
using Xunit;

namespace AIQuotaBar.Providers.Tests.Clash;

public sealed class ClashRouteFilterTests
{
    private static readonly IReadOnlyList<ClashRoute> Routes = new[]
    {
        new ClashRoute("🇯🇵 Tokyo 01", "Vless", 82, IsSelected: false),
        new ClashRoute("日本-家宽-02", "Hysteria2", 95, IsSelected: true),
        new ClashRoute("SG-Singapore-01", "Vmess", 61, IsSelected: false),
        new ClashRoute("US Los Angeles", "Trojan", 140, IsSelected: false),
    };

    [Fact]
    public void FuzzyCountryAliasesMatchFlagChineseAndISOCode()
    {
        var expected = new HashSet<string> { "🇯🇵 Tokyo 01", "日本-家宽-02" };
        foreach (var query in new[] { "🇯🇵", "日本", "JP", "Japan" })
        {
            var result = ClashRouteFilter.Filter(Routes, query, usesRegularExpression: false);

            Assert.True(
                expected.SetEquals(result.Routes.Select(route => route.Name)),
                $"query: {query}（应然命中 {string.Join("/", expected)}，实然 {string.Join("/", result.Routes.Select(route => route.Name))}）");
            Assert.Null(result.ErrorMessage);
        }
    }

    [Fact]
    public void FuzzyFilterStillMatchesArbitraryNodeText()
    {
        var result = ClashRouteFilter.Filter(Routes, "家宽", usesRegularExpression: false);

        Assert.Equal(new[] { "日本-家宽-02" }, result.Routes.Select(route => route.Name).ToArray());
    }

    [Fact]
    public void RegularExpressionSupportsAnchorsAndAlternation()
    {
        var result = ClashRouteFilter.Filter(Routes, "^(🇯🇵|SG-).*(01)$", usesRegularExpression: true);

        var expected = new HashSet<string> { "🇯🇵 Tokyo 01", "SG-Singapore-01" };
        Assert.True(
            expected.SetEquals(result.Routes.Select(route => route.Name)),
            $"应然命中 {string.Join("/", expected)}，实然 {string.Join("/", result.Routes.Select(route => route.Name))}");
        Assert.Null(result.ErrorMessage);
    }

    [Fact]
    public void RegularExpressionMatchesOriginalNameInsteadOfCountryAliases()
    {
        var result = ClashRouteFilter.Filter(Routes, "^JP", usesRegularExpression: true);

        // 应然：正则匹配原始线路名，不做国家别名归一化（"🇯🇵 Tokyo 01" 不以 JP 开头）。
        Assert.Empty(result.Routes);
    }

    [Fact]
    public void InvalidRegularExpressionReturnsErrorAndNoRoutes()
    {
        var result = ClashRouteFilter.Filter(Routes, "^(JP|SG", usesRegularExpression: true);

        Assert.Empty(result.Routes);
        Assert.NotNull(result.ErrorMessage);
    }
}
