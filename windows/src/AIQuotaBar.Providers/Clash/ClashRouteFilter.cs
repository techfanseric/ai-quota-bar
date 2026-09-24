// Swift 来源：AIQuotaBar/Services/Clash/ClashRouteFilter.swift — enum ClashRouteFilter + private CountryAliases（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashRouteFilterTests.swift

#nullable enable

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace AIQuotaBar.Providers.Clash;

/// <summary>
/// 线路搜索过滤器：普通模式按归一化子串 + 国家别名（旗帜/中文/ISO 码）匹配；
/// 正则模式直接匹配原始线路名（忽略大小写），非法模式返回错误信息与空结果。
/// </summary>
public static class ClashRouteFilter
{
    private static readonly Regex ShortCodeExpression = new("^[a-z]{2,3}$", RegexOptions.Compiled);

    public static ClashRouteFilterResult Filter(
        IReadOnlyList<ClashRoute> routes,
        string query,
        bool usesRegularExpression)
    {
        var trimmedQuery = query.Trim();
        if (trimmedQuery.Length == 0)
        {
            return new ClashRouteFilterResult(routes, null);
        }

        if (usesRegularExpression)
        {
            try
            {
                var expression = new Regex(trimmedQuery, RegexOptions.IgnoreCase);
                var filtered = routes
                    .Where(route => expression.IsMatch(route.Name))
                    .ToList();
                return new ClashRouteFilterResult(filtered, null);
            }
            catch (RegexParseException exception)
            {
                return new ClashRouteFilterResult(
                    Array.Empty<ClashRoute>(),
                    exception.Message);
            }
        }

        var normalizedQuery = Normalize(trimmedQuery);
        var queryCountries = CountryAliasTable
            .Where(country => country.Aliases.Any(alias => Normalize(alias) == normalizedQuery))
            .Select(country => country.Code)
            .ToHashSet();

        var filteredRoutes = routes
            .Where(route =>
            {
                if (Normalize(route.Name).Contains(normalizedQuery, StringComparison.Ordinal))
                {
                    return true;
                }

                if (queryCountries.Count == 0)
                {
                    return false;
                }

                var routeCountries = CountryAliasTable
                    .Where(country => country.Aliases.Any(alias => ContainsAlias(alias, route.Name)))
                    .Select(country => country.Code)
                    .ToHashSet();
                return routeCountries.Overlaps(queryCountries);
            })
            .ToList();

        return new ClashRouteFilterResult(filteredRoutes, null);
    }

    /// <summary>
    /// Swift folding(.caseInsensitive + .diacriticInsensitive + .widthInsensitive) 的 .NET 镜像：
    /// FormKC 折叠全半角，FormD 后剥离组合记号再去音符号，最后小写 + 去首尾空白。
    /// </summary>
    private static string Normalize(string value)
    {
        var widthFolded = value.Normalize(NormalizationForm.FormKC);
        var decomposed = widthFolded.Normalize(NormalizationForm.FormD);
        var builder = new StringBuilder(decomposed.Length);
        foreach (var character in decomposed)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(character) != UnicodeCategory.NonSpacingMark)
            {
                builder.Append(character);
            }
        }

        return builder
            .ToString()
            .Normalize(NormalizationForm.FormC)
            .ToLowerInvariant()
            .Trim();
    }

    private static bool ContainsAlias(string alias, string name)
    {
        var normalizedAlias = Normalize(alias);
        var normalizedName = Normalize(name);

        // 短别名（2-3 个字母的 ISO 码）要求词边界，避免 "SG" 命中 "USGS-01"；
        // 其余别名（旗帜、中文等）按归一化子串匹配。
        if (!ShortCodeExpression.IsMatch(normalizedAlias))
        {
            return normalizedName.Contains(normalizedAlias, StringComparison.Ordinal);
        }

        var pattern = $"(^|[^a-z]){Regex.Escape(normalizedAlias)}([^a-z]|$)";
        var expression = new Regex(pattern, RegexOptions.IgnoreCase);
        return expression.IsMatch(normalizedName);
    }

    private static readonly CountryAliases[] CountryAliasTable =
    {
        new("JP", new[] { "🇯🇵", "日本", "Japan", "JP" }),
        new("SG", new[] { "🇸🇬", "新加坡", "Singapore", "SG" }),
        new("US", new[] { "🇺🇸", "美国", "United States", "USA", "US" }),
        new("HK", new[] { "🇭🇰", "香港", "Hong Kong", "HK" }),
        new("TW", new[] { "🇹🇼", "台湾", "臺灣", "Taiwan", "TW" }),
        new("KR", new[] { "🇰🇷", "韩国", "韓國", "Korea", "KR" }),
        new("GB", new[] { "🇬🇧", "英国", "英國", "United Kingdom", "UK", "GB" }),
        new("DE", new[] { "🇩🇪", "德国", "德國", "Germany", "DE" }),
        new("FR", new[] { "🇫🇷", "法国", "法國", "France", "FR" }),
        new("CA", new[] { "🇨🇦", "加拿大", "Canada", "CA" }),
        new("AU", new[] { "🇦🇺", "澳洲", "澳大利亚", "Australia", "AU" }),
        new("NL", new[] { "🇳🇱", "荷兰", "荷蘭", "Netherlands", "NL" }),
    };

    private sealed record CountryAliases(string Code, IReadOnlyList<string> Aliases);
}
