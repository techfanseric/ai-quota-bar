using Xunit;

namespace AQB.Clash.Tests;

public class CountryMatcherTests
{
    private static readonly string[] Routes =
    {
        "🇯🇵 Tokyo 01",
        "日本-家宽-02",
        "SG-Singapore-01",
        "US Los Angeles",
    };

    [Fact]
    public void FuzzyCountryAliasesMatchFlagChineseAndIsoCodeIdentically()
    {
        foreach (var query in new[] { "🇯🇵", "日本", "JP", "Japan", "jp" })
        {
            var result = CountryMatcher.FilterNames(Routes, query, usesRegularExpression: false);

            Assert.Null(result.ErrorMessage);
            Assert.Equal(
                new HashSet<string> { "🇯🇵 Tokyo 01", "日本-家宽-02" },
                result.Matches.ToHashSet());
        }
    }

    [Fact]
    public void FuzzyFilterMatchesArbitraryNodeText()
    {
        var result = CountryMatcher.FilterNames(Routes, "家宽", usesRegularExpression: false);

        Assert.Null(result.ErrorMessage);
        Assert.Equal(new[] { "日本-家宽-02" }, result.Matches);
    }

    [Fact]
    public void ShortIsoAliasesDoNotMatchInsideLongerWords()
    {
        // Country-alias matching (via the CJK alias) must not let "US" hit "Russia".
        var names = new[] { "Russia Node", "US Los Angeles" };

        var result = CountryMatcher.FilterNames(names, "美国", usesRegularExpression: false);

        Assert.Equal(new[] { "US Los Angeles" }, result.Matches);
    }

    [Fact]
    public void FullWidthCharactersFoldBeforeMatching()
    {
        var names = new[] { "ＵＳ Los Angeles", "Japan Osaka" };

        var result = CountryMatcher.FilterNames(names, "US", usesRegularExpression: false);

        Assert.Equal(new[] { "ＵＳ Los Angeles" }, result.Matches);
        Assert.Equal("us los angeles", CountryMatcher.Normalize("ＵＳ Los Angeles"));
    }

    [Fact]
    public void QueryCountriesMapsAliasesToCodes()
    {
        Assert.Equal(new[] { "JP" }, CountryMatcher.QueryCountries("日本"));
        Assert.Equal(new[] { "JP" }, CountryMatcher.QueryCountries("JP"));
        Assert.Equal(new[] { "US" }, CountryMatcher.QueryCountries("United States"));
        Assert.Empty(CountryMatcher.QueryCountries("家宽"));
    }

    [Fact]
    public void CountryTableKeepsTwelveCountriesWithCanonicalAliases()
    {
        Assert.Equal(12, CountryMatcher.Countries.Count);

        var jp = CountryMatcher.Countries.Single(country => country.Code == "JP");
        Assert.Equal(new[] { "🇯🇵", "日本", "Japan", "JP" }, jp.Aliases);

        var us = CountryMatcher.Countries.Single(country => country.Code == "US");
        Assert.Equal(new[] { "🇺🇸", "美国", "United States", "USA", "US" }, us.Aliases);
    }

    [Fact]
    public void RegexModeMatchesRawNamesWithAnchorsAndAlternation()
    {
        var result = CountryMatcher.FilterNames(Routes, @"^(🇯🇵|SG-).*(01)$", usesRegularExpression: true);

        Assert.Null(result.ErrorMessage);
        Assert.Equal(
            new HashSet<string> { "🇯🇵 Tokyo 01", "SG-Singapore-01" },
            result.Matches.ToHashSet());
    }

    [Fact]
    public void RegexModeMatchesOriginalNamesInsteadOfCountryAliases()
    {
        var result = CountryMatcher.FilterNames(Routes, "^JP", usesRegularExpression: true);

        Assert.Null(result.ErrorMessage);
        Assert.Empty(result.Matches);
    }

    [Fact]
    public void InvalidRegexReturnsErrorAndNoRoutes()
    {
        var result = CountryMatcher.FilterNames(Routes, @"^(JP|SG", usesRegularExpression: true);

        Assert.Empty(result.Matches);
        Assert.NotNull(result.ErrorMessage);
    }

    [Fact]
    public void IsRegexValidTellsGoodPatternsFromBadOnes()
    {
        Assert.True(CountryMatcher.IsRegexValid("^JP.*"));
        Assert.False(CountryMatcher.IsRegexValid("^(JP|SG"));
    }

    [Fact]
    public void EmptyQueryReturnsEverything()
    {
        var result = CountryMatcher.FilterNames(Routes, "   ", usesRegularExpression: false);

        Assert.Null(result.ErrorMessage);
        Assert.Equal(4, result.Matches.Count);
    }
}
