using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace AQB.Clash;

public sealed record CountryAliasSet(string Code, IReadOnlyList<string> Aliases);

public sealed record FilterResult<T>(IReadOnlyList<T> Matches, string? ErrorMessage);

/// <summary>
/// Country alias matching (12 countries) plus the route filter modes: fuzzy country/contains
/// matching with NFKC width folding, and a regex mode applied to the raw node names.
/// </summary>
public static class CountryMatcher
{
    /// <summary>12 country alias tables; must stay identical to the macOS table.</summary>
    public static readonly IReadOnlyList<CountryAliasSet> Countries = new[]
    {
        new CountryAliasSet("JP", new[] { "🇯🇵", "日本", "Japan", "JP" }),
        new CountryAliasSet("SG", new[] { "🇸🇬", "新加坡", "Singapore", "SG" }),
        new CountryAliasSet("US", new[] { "🇺🇸", "美国", "United States", "USA", "US" }),
        new CountryAliasSet("HK", new[] { "🇭🇰", "香港", "Hong Kong", "HK" }),
        new CountryAliasSet("TW", new[] { "🇹🇼", "台湾", "臺灣", "Taiwan", "TW" }),
        new CountryAliasSet("KR", new[] { "🇰🇷", "韩国", "韓國", "Korea", "KR" }),
        new CountryAliasSet("GB", new[] { "🇬🇧", "英国", "英國", "United Kingdom", "UK", "GB" }),
        new CountryAliasSet("DE", new[] { "🇩🇪", "德国", "德國", "Germany", "DE" }),
        new CountryAliasSet("FR", new[] { "🇫🇷", "法国", "法國", "France", "FR" }),
        new CountryAliasSet("CA", new[] { "🇨🇦", "加拿大", "Canada", "CA" }),
        new CountryAliasSet("AU", new[] { "🇦🇺", "澳洲", "澳大利亚", "Australia", "AU" }),
        new CountryAliasSet("NL", new[] { "🇳🇱", "荷兰", "荷蘭", "Netherlands", "NL" }),
    };

    private static readonly Regex ShortAsciiAliasPattern = new("^[a-z]{2,3}$", RegexOptions.CultureInvariant);

    /// <summary>NFKC (folds full-width to half-width) + invariant lowercase + trim.</summary>
    public static string Normalize(string value)
    {
        string normalized;
        try
        {
            normalized = value.Normalize(NormalizationForm.FormKC);
        }
        catch (ArgumentException)
        {
            normalized = value;
        }

        return normalized.ToLowerInvariant().Trim();
    }

    /// <summary>Whether the pattern compiles as a .NET regular expression.</summary>
    public static bool IsRegexValid(string pattern)
    {
        try
        {
            _ = new Regex(pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            return true;
        }
        catch (ArgumentException)
        {
            return false;
        }
    }

    /// <summary>Countries whose alias list contains an alias exactly equal to the (normalized) query.</summary>
    public static IReadOnlyCollection<string> QueryCountries(string query)
    {
        var normalizedQuery = Normalize(query);
        return Countries
            .Where(country => country.Aliases.Any(alias => Normalize(alias) == normalizedQuery))
            .Select(country => country.Code)
            .ToArray();
    }

    /// <summary>
    /// Alias containment: short ASCII aliases (JP/SG/US...) match on word boundaries to avoid
    /// "us" hitting "Russia"; flags and CJK aliases match by containment.
    /// </summary>
    public static bool ContainsAlias(string alias, string name)
    {
        var normalizedAlias = Normalize(alias);
        var normalizedName = Normalize(name);

        if (!ShortAsciiAliasPattern.IsMatch(normalizedAlias))
        {
            return normalizedName.Contains(normalizedAlias, StringComparison.Ordinal);
        }

        var pattern = "(^|[^a-z])" + Regex.Escape(normalizedAlias) + "([^a-z]|$)";
        return Regex.IsMatch(normalizedName, pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    }

    /// <summary>
    /// Filters items. Empty/whitespace query returns everything. Regex mode matches the raw
    /// (non-normalized) names case-insensitively; invalid regex yields no matches plus an error.
    /// Fuzzy mode: normalized containment, then country alias intersection.
    /// </summary>
    public static FilterResult<T> Filter<T>(
        IReadOnlyList<T> items,
        Func<T, string> nameOf,
        string query,
        bool usesRegularExpression)
    {
        var trimmedQuery = query.Trim();
        if (trimmedQuery.Length == 0)
        {
            return new FilterResult<T>(items, null);
        }

        if (usesRegularExpression)
        {
            if (!IsRegexValid(trimmedQuery))
            {
                return new FilterResult<T>(Array.Empty<T>(), "Invalid regular expression: " + trimmedQuery);
            }

            var expression = new Regex(trimmedQuery, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            return new FilterResult<T>(items.Where(item => expression.IsMatch(nameOf(item))).ToArray(), null);
        }

        var normalizedQuery = Normalize(trimmedQuery);
        var queryCountries = QueryCountries(trimmedQuery);

        var matches = items.Where(item =>
        {
            var name = nameOf(item);
            if (Normalize(name).Contains(normalizedQuery, StringComparison.Ordinal))
            {
                return true;
            }

            if (queryCountries.Count == 0)
            {
                return false;
            }

            var routeCountries = Countries
                .Where(country => country.Aliases.Any(alias => ContainsAlias(alias, name)))
                .Select(country => country.Code);
            return routeCountries.Any(code => queryCountries.Contains(code));
        }).ToArray();

        return new FilterResult<T>(matches, null);
    }

    /// <summary>Convenience overload filtering plain name lists.</summary>
    public static FilterResult<string> FilterNames(IReadOnlyList<string> names, string query, bool usesRegularExpression)
        => Filter(names, name => name, query, usesRegularExpression);
}
