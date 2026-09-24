// Swift 来源（逐条对照）：
//   - CodexAdditionalRateLimitsTests.swift（maps additional spark limit… / keeps valid spark window
//     when an additional limit sibling is malformed / keeps primary usage when every additional limit
//     element is malformed / omits extra rate windows when additional limits are absent /
//     tolerates malformed additional limits while keeping primary window / skips additional limits
//     without a usable window / maps non spark additional limit using a slugged id /
//     dedupes split spark entries by window kind）
//   - CodexOAuthTests.swift（maps usage windows from O auth / O auth response with precise windows maps
//     to exact confidence / O auth response with malformed additional window maps to unknown confidence /
//     maps free weekly only window into secondary / keeps single session window as primary /
//     preserves unknown single window as primary / preserves unknown secondary only window as primary /
//     swaps reversed weekly and unknown windows / returns nil when O auth usage has no windows /
//     keeps valid window when secondary window is malformed / decodes credits balance string /
//     ignores malformed credits payload while keeping usage）
//   - CodexPATTests.swift（PAT whoami / PAT usage mapping keeps pat source）
//   - CodexWorkspaceBalanceTests.swift（decodeBalance 系）
//   - CodexRateLimitResetCreditsTests.swift（rejects negative available count / decodes credits…）
// fixtures：windows/contracts/fixtures/codex/ 全部 usage-response-*、whoami、rate-limit-reset-credits、
//   workspace-remaining-balance、usage-snapshot-current。

#nullable enable

using System;
using System.Linq;
using System.Text.Json.Nodes;
using AIQuotaBar.Core.Contracts;
using AIQuotaBar.Providers.Codex.Credentials;
using AIQuotaBar.Providers.Codex.Parsing;
using Xunit;

namespace AIQuotaBar.Providers.Tests.Codex;

public sealed class CodexUsageParserTests
{
    private static readonly DateTimeOffset Now = new(2026, 9, 24, 0, 0, 0, TimeSpan.Zero);

    private static CodexUsageResponse ParseFixture(string fixtureName) =>
        CodexUsageParser.ParseUsageResponse(CodexFixtures.Read(fixtureName));

    private static CodexOAuthCredentials OAuthCredentials() => new(
        AccessToken: "access",
        RefreshToken: "refresh",
        IdToken: null,
        AccountId: null,
        LastRefresh: Now);

    // ------------------------------------------------------------------
    // usage-response-pro-spark.json
    // ------------------------------------------------------------------

    [Fact]
    public void ProSpark_DecodesWindowsPlanAndAdditionalLimits()
    {
        var response = ParseFixture("usage-response-pro-spark.json");

        Assert.Equal("pro", response.PlanType);
        Assert.Null(response.AccountId);
        Assert.Equal(22, response.RateLimit!.PrimaryWindow!.UsedPercent);
        Assert.Equal(1766948068, response.RateLimit!.PrimaryWindow!.ResetAt);
        Assert.Equal(18000, response.RateLimit!.PrimaryWindow!.LimitWindowSeconds);
        Assert.Equal(43, response.RateLimit!.SecondaryWindow!.UsedPercent);
        Assert.Equal(604800, response.RateLimit!.SecondaryWindow!.LimitWindowSeconds);
        Assert.Null(response.Credits);
        var additional = Assert.Single(response.AdditionalRateLimits!);
        Assert.Equal("GPT-5.3-Codex-Spark", additional.LimitName);
        Assert.Equal("gpt_5_3_codex_spark", additional.MeteredFeature);
        Assert.Equal(30, additional.RateLimit!.PrimaryWindow!.UsedPercent);
        Assert.Equal(100, additional.RateLimit!.SecondaryWindow!.UsedPercent);
        Assert.False(response.AdditionalRateLimitsDecodeFailed);
    }

    [Fact]
    public void ProSpark_MapsSparkIntoNamedExtraWindows()
    {
        // Swift: maps additional spark limit into a named extra rate window。
        var snapshot = CodexUsageParser.MapUsageSnapshot(
            ParseFixture("usage-response-pro-spark.json"), OAuthCredentials(), now: Now);

        Assert.NotNull(snapshot);
        Assert.Equal(22, snapshot!.Primary!.UsedPercent);
        Assert.Equal(300, snapshot.Primary!.WindowMinutes);
        Assert.Equal(43, snapshot.Secondary!.UsedPercent);
        Assert.Equal(10080, snapshot.Secondary!.WindowMinutes);
        Assert.Equal(
            new DateTimeOffset(2025, 12, 28, 18, 54, 28, TimeSpan.Zero),
            snapshot.Primary!.ResetsAt);

        var extras = snapshot.ExtraRateWindows!;
        Assert.Equal(2, extras.Count);
        Assert.Equal("codex-spark", extras[0].Id);
        Assert.Equal("Codex Spark 5-hour", extras[0].Title);
        Assert.Equal(30, extras[0].Window.UsedPercent);
        Assert.Equal(300, extras[0].Window.WindowMinutes);
        Assert.NotNull(extras[0].Window.ResetsAt);
        Assert.Equal("codex-spark-weekly", extras[1].Id);
        Assert.Equal("Codex Spark Weekly", extras[1].Title);
        Assert.Equal(100, extras[1].Window.UsedPercent);
        Assert.Equal(10080, extras[1].Window.WindowMinutes);
    }

    [Fact]
    public void ProSpark_MapsToUsageDataWithFourRows()
    {
        var data = CodexUsageParser.MapToUsageData(
            ParseFixture("usage-response-pro-spark.json"),
            OAuthCredentials(),
            whoami: null,
            sourceLabel: "oauth",
            now: Now);

        Assert.Equal(UsageProvider.Codex, data.Provider);
        Assert.Equal(4, data.Models.Count);
        Assert.Equal(new[] { "5h", "Weekly", "Codex Spark 5-hour", "Codex Spark Weekly" },
            data.Models.Select(model => model.ModelName).ToArray());

        var fiveHour = data.Models[0];
        Assert.Equal(100, fiveHour.CurrentIntervalTotal);
        Assert.Equal(78, fiveHour.CurrentIntervalRemaining);
        Assert.Equal(78, fiveHour.CurrentIntervalRemainingPercent);
        Assert.Equal("%", fiveHour.ValueSuffix);
        Assert.Equal(
            new DateTimeOffset(2025, 12, 28, 18, 54, 28, TimeSpan.Zero),
            fiveHour.EndTime);
        Assert.Equal(fiveHour.EndTime!.Value.AddMinutes(-300), fiveHour.StartTime);
        Assert.Equal("Pro 20x · OAuth · resets 12/29 02:54", fiveHour.DetailText);

        Assert.Equal(57, data.Models[1].CurrentIntervalRemaining);
        Assert.Equal(70, data.Models[2].CurrentIntervalRemaining);
        Assert.Equal(0, data.Models[3].CurrentIntervalRemaining);

        // remains：spark weekly 已 100% 用满不计入；其余 3 行有余量。
        Assert.Equal(3, data.Remains);
        Assert.Equal(4, data.Total);
        Assert.Equal(Now, data.Timestamp);
    }

    // ------------------------------------------------------------------
    // usage-response-oauth-windows.json
    // ------------------------------------------------------------------

    [Fact]
    public void OauthWindows_MapsWithoutPlanTypeWithExactConfidence()
    {
        // Swift: maps usage windows from O auth + O auth response with precise windows maps to
        // exact confidence（无 plan_type 也能映射）。
        var response = ParseFixture("usage-response-oauth-windows.json");
        var snapshot = CodexUsageParser.MapUsageSnapshot(response, OAuthCredentials(), now: Now);

        Assert.NotNull(snapshot);
        Assert.Equal(22, snapshot!.Primary!.UsedPercent);
        Assert.Equal(300, snapshot.Primary!.WindowMinutes);
        Assert.Equal(43, snapshot.Secondary!.UsedPercent);
        Assert.Equal(10080, snapshot.Secondary!.WindowMinutes);
        Assert.NotNull(snapshot.Primary!.ResetsAt);
        Assert.NotNull(snapshot.Secondary!.ResetsAt);
        Assert.Equal(CodexDataConfidence.Exact, snapshot.DataConfidence);
    }

    // ------------------------------------------------------------------
    // usage-response-free-weekly-only.json
    // ------------------------------------------------------------------

    [Fact]
    public void FreeWeeklyOnly_MovesWeeklyWindowIntoSecondary()
    {
        // Swift: maps free weekly only window into secondary —— primary 含 604800s 时必须映射
        // 为 secondary(weekly)，primary 为空。
        var response = ParseFixture("usage-response-free-weekly-only.json");
        var snapshot = CodexUsageParser.MapUsageSnapshot(response, OAuthCredentials(), now: Now);

        Assert.NotNull(snapshot);
        Assert.Null(snapshot!.Primary);
        Assert.Equal(0, snapshot.Secondary!.UsedPercent);
        Assert.Equal(10080, snapshot.Secondary!.WindowMinutes);

        var data = CodexUsageParser.MapToUsageData(
            response, OAuthCredentials(), whoami: null, sourceLabel: "oauth", now: Now);
        var weekly = Assert.Single(data.Models);
        Assert.Equal("Weekly", weekly.ModelName);
        Assert.Equal(100, weekly.CurrentIntervalRemainingPercent);
        Assert.Equal("Free · OAuth · resets 04/06 17:44", weekly.DetailText);
    }

    // ------------------------------------------------------------------
    // usage-response-unknown-window.json
    // ------------------------------------------------------------------

    [Fact]
    public void UnknownWindow_PreservedAsPrimaryWithRawMinutes()
    {
        // Swift: preserves unknown single window as primary —— 32400s(9h) 不得丢弃或归为 5h。
        var snapshot = CodexUsageParser.MapUsageSnapshot(
            ParseFixture("usage-response-unknown-window.json"), OAuthCredentials(), now: Now);

        Assert.NotNull(snapshot);
        Assert.Null(snapshot!.Secondary);
        Assert.Equal(17, snapshot.Primary!.UsedPercent);
        Assert.Equal(540, snapshot.Primary!.WindowMinutes);
    }

    // ------------------------------------------------------------------
    // usage-response-pat-team-weekly.json + whoami-response-pat.json
    // ------------------------------------------------------------------

    [Fact]
    public void PatTeamWeekly_MapsWhoamiIdentityAndWeeklyWindow()
    {
        // Swift: PAT usage mapping keeps pat source —— 账号邮箱/计划来自 whoami 而非该响应。
        var response = ParseFixture("usage-response-pat-team-weekly.json");
        var whoami = CodexUsageParser.ParseWhoami(CodexFixtures.Read("whoami-response-pat.json"));

        var data = CodexUsageParser.MapToUsageData(
            response, credentials: null, whoami: whoami, sourceLabel: "pat", now: Now);

        var weekly = Assert.Single(data.Models);
        Assert.Equal("Weekly", weekly.ModelName);
        Assert.Equal(32, weekly.CurrentIntervalRemaining);
        Assert.Equal("pat@example.com", weekly.AccountName);
        Assert.Equal("Team · Pat · resets 12/29 02:54", weekly.DetailText);
    }

    [Fact]
    public void Whoami_DecodesAccountPlanAndEmail()
    {
        var whoami = CodexUsageParser.ParseWhoami(CodexFixtures.Read("whoami-response-pat.json"));

        Assert.Equal("acct-pat", whoami.AccountId);
        Assert.Equal("pat@example.com", whoami.Email);
        Assert.Equal("team", whoami.PlanType);
    }

    // ------------------------------------------------------------------
    // usage-response-credits-balance-string.json
    // ------------------------------------------------------------------

    [Fact]
    public void CreditsBalanceString_DecodesAsZero()
    {
        // Swift: decodes credits balance string —— balance 可为字符串 "0"。
        var response = ParseFixture("usage-response-credits-balance-string.json");

        Assert.Equal("pro", response.PlanType);
        Assert.Equal(0, response.Credits!.Balance);
        Assert.False(response.Credits!.HasCredits);
        Assert.False(response.Credits!.Unlimited);

        var credits = CodexUsageParser.MapCredits(response, Now);
        Assert.NotNull(credits);
        Assert.Equal(0, credits!.Remaining);
        Assert.True(credits.BalanceReadSucceeded);
        // CreditsAvailable 为 bool?（xUnit 2.7.0 无可空布尔重载），显式折叠后断言。
        Assert.False(credits.CreditsAvailable ?? false);
    }

    [Fact]
    public void CreditsBalanceString_MapsCreditsRowOnFixedThousandScale()
    {
        var data = CodexUsageParser.MapToUsageData(
            ParseFixture("usage-response-credits-balance-string.json"),
            OAuthCredentials(),
            whoami: null,
            sourceLabel: "oauth",
            now: Now);

        Assert.Equal(2, data.Models.Count);
        Assert.Equal(88, data.Models[0].CurrentIntervalRemaining);

        var creditsRow = data.Models[1];
        Assert.Equal("Credits", creditsRow.ModelName);
        Assert.Equal(1000, creditsRow.CurrentIntervalTotal);
        Assert.Equal(0, creditsRow.CurrentIntervalRemaining);
        Assert.Equal(" left", creditsRow.ValueSuffix);
        Assert.Null(creditsRow.CurrentIntervalRemainingPercent);
        Assert.Equal(0, creditsRow.ProgressBarPercentOverride);
        Assert.Equal("1K tokens", creditsRow.ProgressBarRightText);
        Assert.Null(creditsRow.EndTime);
    }

    // ------------------------------------------------------------------
    // usage-response-business-workspace-credits.json
    // ------------------------------------------------------------------

    [Fact]
    public void BusinessWorkspaceCredits_IndividualLimitIsQuotaCapSemantics()
    {
        // Swift: 根级 individual_limit{limit,used} 为额度上限语义（remaining = limit - used = 100）；
        // balance 可为 null；account_id 供工作区余额端点做账号匹配。
        var response = ParseFixture("usage-response-business-workspace-credits.json");

        Assert.Equal("workspace-fixture", response.AccountId);
        Assert.Equal("business", response.PlanType);
        Assert.Null(response.Credits!.Balance);
        Assert.True(response.Credits!.HasCredits);

        var credits = CodexUsageParser.MapCredits(response, Now);
        Assert.NotNull(credits);
        Assert.False(credits!.BalanceReadSucceeded);
        Assert.Equal(0, credits.Remaining);
        Assert.Equal(400, credits.CreditLimit!.Limit);
        Assert.Equal(300, credits.CreditLimit!.Used);
        Assert.Equal(100, credits.CreditLimit!.Remaining);
        Assert.Equal(100, credits.DisplayRemaining);
    }

    [Fact]
    public void BusinessWorkspaceCredits_RootIndividualLimitAcceptsCamelCaseKey()
    {
        // Swift: 根级 individual_limit 有 snake → camel 双键（.individualLimit ?? .individualLimitCamel）。
        var json = CodexFixtures.Transform("usage-response-business-workspace-credits.json", root =>
        {
            var limit = (JsonObject)root["individual_limit"]!;
            root.Remove("individual_limit");
            root["individualLimit"] = limit;
        });

        var response = CodexUsageParser.ParseUsageResponse(json);
        var credits = CodexUsageParser.MapCredits(response, Now);

        Assert.NotNull(response.IndividualLimit);
        Assert.Equal(400, credits!.CreditLimit!.Limit);
        Assert.Equal(300, credits.CreditLimit!.Used);
        Assert.Equal(100, credits.CreditLimit!.Remaining);
    }

    [Fact]
    public void BusinessWorkspaceCredits_CreditsOnlyResponseKeepsPartialResult()
    {
        // Swift: credits only O auth payload still returns credits result —— 无窗口时保留部分结果。
        var data = CodexUsageParser.MapToUsageData(
            ParseFixture("usage-response-business-workspace-credits.json"),
            credentials: null,
            whoami: null,
            sourceLabel: "oauth",
            now: Now);

        var creditsRow = Assert.Single(data.Models);
        Assert.Equal("Credits", creditsRow.ModelName);
        Assert.Equal("Business · OAuth", creditsRow.DetailText);
        Assert.Equal(0, data.Remains);
        Assert.Equal(1, data.Total);
    }

    // ------------------------------------------------------------------
    // usage-response-additional-malformed-siblings.json
    // ------------------------------------------------------------------

    [Fact]
    public void AdditionalMalformedSiblings_SkipsBadEntriesAndKeepsSpark()
    {
        // Swift: keeps valid spark window when an additional limit sibling is malformed。
        var response = ParseFixture("usage-response-additional-malformed-siblings.json");
        var snapshot = CodexUsageParser.MapUsageSnapshot(response, OAuthCredentials(), now: Now);

        Assert.NotNull(snapshot);
        Assert.Equal(22, snapshot!.Primary!.UsedPercent);
        Assert.Equal(43, snapshot.Secondary!.UsedPercent);

        var extra = Assert.Single(snapshot.ExtraRateWindows!);
        Assert.Equal("codex-spark", extra.Id);
        Assert.Equal(30, extra.Window.UsedPercent);

        // 非对象兄弟导致 additional 解码有损 → unknown 置信度（Swift LossyAdditionalRateLimit）。
        Assert.True(response.AdditionalRateLimitsDecodeFailed);
        Assert.Equal(CodexDataConfidence.Unknown, snapshot.DataConfidence);
    }

    [Fact]
    public void AdditionalMalformedSiblings_MapToUsageDataKeepsPrimaryAndWeekly()
    {
        var data = CodexUsageParser.MapToUsageData(
            ParseFixture("usage-response-additional-malformed-siblings.json"),
            OAuthCredentials(),
            whoami: null,
            sourceLabel: "oauth",
            now: Now);

        Assert.Equal(3, data.Models.Count);
        Assert.Equal(new[] { "5h", "Weekly", "Codex Spark 5-hour" },
            data.Models.Select(model => model.ModelName).ToArray());
    }

    // ------------------------------------------------------------------
    // fixture 派生：损失容忍与置信度边界（Swift malformed 系列用例）。
    // ------------------------------------------------------------------

    [Fact]
    public void MalformedAdditionalWindow_DowngradesConfidenceToUnknown()
    {
        // Swift: O auth response with malformed additional window maps to unknown confidence。
        var json = CodexFixtures.Transform("usage-response-pro-spark.json", root =>
        {
            var spark = (JsonObject)root["additional_rate_limits"]![0]!;
            spark["rate_limit"] = new JsonObject
            {
                ["primary_window"] = new JsonObject { ["used_percent"] = "bad" },
            };
        });

        var snapshot = CodexUsageParser.MapUsageSnapshot(
            CodexUsageParser.ParseUsageResponse(json), OAuthCredentials(), now: Now);

        Assert.NotNull(snapshot);
        Assert.Equal(22, snapshot!.Primary!.UsedPercent);
        Assert.Null(snapshot.ExtraRateWindows);
        Assert.Equal(CodexDataConfidence.Unknown, snapshot.DataConfidence);
    }

    [Fact]
    public void MalformedPrimaryWindow_KeepsWeeklyWindow()
    {
        // Swift: auto/explicit oauth keeps weekly window when primary window is malformed。
        var json = CodexFixtures.Transform("usage-response-oauth-windows.json", root =>
        {
            var rateLimit = (JsonObject)root["rate_limit"]!;
            ((JsonObject)rateLimit["primary_window"]!)["used_percent"] = "bad";
        });

        var snapshot = CodexUsageParser.MapUsageSnapshot(
            CodexUsageParser.ParseUsageResponse(json), OAuthCredentials(), now: Now);

        Assert.NotNull(snapshot);
        Assert.Null(snapshot!.Primary);
        Assert.Equal(43, snapshot.Secondary!.UsedPercent);
        Assert.Equal(10080, snapshot.Secondary!.WindowMinutes);
        Assert.Equal(CodexDataConfidence.Unknown, snapshot.DataConfidence);
    }

    [Fact]
    public void NoWindows_AtAll_ReturnsNullSnapshot()
    {
        // Swift: returns nil when O auth usage has no windows。
        var json = CodexFixtures.Transform("usage-response-oauth-windows.json", root =>
        {
            var rateLimit = (JsonObject)root["rate_limit"]!;
            rateLimit["primary_window"] = null;
            rateLimit["secondary_window"] = null;
        });

        var snapshot = CodexUsageParser.MapUsageSnapshot(
            CodexUsageParser.ParseUsageResponse(json), OAuthCredentials(), now: Now);

        Assert.Null(snapshot);
    }

    [Fact]
    public void MalformedCreditsPayload_IgnoredWhileKeepingUsage()
    {
        // Swift: ignores malformed credits payload while keeping usage（balance 为数组 → null）。
        var json = CodexFixtures.Transform("usage-response-credits-balance-string.json", root =>
        {
            ((JsonObject)root["credits"]!)["balance"] = new JsonArray();
        });

        var response = CodexUsageParser.ParseUsageResponse(json);
        Assert.Null(response.Credits!.Balance);
        Assert.False(response.Credits!.HasCredits);

        var snapshot = CodexUsageParser.MapUsageSnapshot(response, OAuthCredentials(), now: Now);
        Assert.Equal(12, snapshot!.Primary!.UsedPercent);
    }

    [Fact]
    public void AdditionalLimitsNotAnArray_ToleratedWithPrimaryKept()
    {
        // Swift: tolerates malformed additional limits while keeping primary window。
        var json = CodexFixtures.Transform("usage-response-oauth-windows.json", root =>
        {
            root["additional_rate_limits"] = "unexpected";
        });

        var response = CodexUsageParser.ParseUsageResponse(json);
        Assert.Null(response.AdditionalRateLimits);
        Assert.True(response.AdditionalRateLimitsDecodeFailed);

        var snapshot = CodexUsageParser.MapUsageSnapshot(response, OAuthCredentials(), now: Now);
        Assert.Equal(22, snapshot!.Primary!.UsedPercent);
    }

    [Fact]
    public void AdditionalLimitWithoutUsableWindow_ProducesNoExtra()
    {
        // Swift: skips additional limits without a usable window（rate_limit: null）。
        var json = CodexFixtures.Transform("usage-response-pro-spark.json", root =>
        {
            var spark = (JsonObject)root["additional_rate_limits"]![0]!;
            spark["rate_limit"] = null;
        });

        var snapshot = CodexUsageParser.MapUsageSnapshot(
            CodexUsageParser.ParseUsageResponse(json), OAuthCredentials(), now: Now);

        Assert.NotNull(snapshot);
        Assert.Null(snapshot!.ExtraRateWindows);
    }

    [Fact]
    public void NonSparkAdditionalLimit_UsesSluggedIdAndDeduplicates()
    {
        // Swift: maps non spark additional limit using a slugged id（重复 ID 收敛到首次出现）。
        var json = CodexFixtures.Transform("usage-response-pro-spark.json", root =>
        {
            var first = (JsonObject)root["additional_rate_limits"]![0]!;
            first["limit_name"] = "GPT-5.3-Codex-Mini";
            first["metered_feature"] = "gpt_5_3_codex_mini";

            // 第二条同名条目：重复 slug，应去重保留第一条。
            var second = (JsonObject)first.DeepClone();
            var secondRateLimit = (JsonObject)second["rate_limit"]!;
            var secondPrimary = (JsonObject)secondRateLimit["primary_window"]!;
            secondPrimary["used_percent"] = 99;
            ((JsonArray)root["additional_rate_limits"]!).Add(second);
        });

        var snapshot = CodexUsageParser.MapUsageSnapshot(
            CodexUsageParser.ParseUsageResponse(json), OAuthCredentials(), now: Now);

        var extra = Assert.Single(snapshot!.ExtraRateWindows!);
        Assert.Equal("codex-gpt-5-3-codex-mini", extra.Id);
        Assert.Equal("GPT-5.3-Codex-Mini", extra.Title);
        Assert.Equal(30, extra.Window.UsedPercent);
    }

    [Fact]
    public void SplitSparkEntries_DedupeByWindowKind()
    {
        // Swift: dedupes split spark entries by window kind —— 同 spark 的 5h/weekly 两条独立窗口。
        var json = CodexFixtures.Transform("usage-response-additional-malformed-siblings.json", root =>
        {
            var original = (JsonArray)root["additional_rate_limits"]!;
            var spark = (JsonObject)original[1]!; // 合法 Spark 条目（两侧的非对象元素丢弃）

            var weekly = (JsonObject)spark.DeepClone();
            weekly["limit_name"] = "GPT-5.3-Codex-Spark Weekly";
            var weeklyRateLimit = (JsonObject)weekly["rate_limit"]!;
            var weeklyPrimary = (JsonObject)weeklyRateLimit["primary_window"]!;
            weeklyPrimary["used_percent"] = 80;
            weeklyPrimary["reset_at"] = 1767407914;
            weeklyPrimary["limit_window_seconds"] = 604800;

            root["additional_rate_limits"] = new JsonArray(spark.DeepClone(), weekly);
        });

        var snapshot = CodexUsageParser.MapUsageSnapshot(
            CodexUsageParser.ParseUsageResponse(json), OAuthCredentials(), now: Now);

        Assert.NotNull(snapshot);
        // 提升为局部变量：属性空态不跨语句跟踪（`!` 只影响当次表达式）。
        var extras = snapshot!.ExtraRateWindows!;
        Assert.Equal(
            new[] { "codex-spark", "codex-spark-weekly" },
            extras.Select(extra => extra.Id).ToArray());
        Assert.Equal(30, extras[0].Window.UsedPercent);
        Assert.Equal(80, extras[1].Window.UsedPercent);
    }

    // ------------------------------------------------------------------
    // 窗口归一（Swift CodexOAuthTests 的 reversed/unknown 组合，直接驱动 Normalizer）。
    // ------------------------------------------------------------------

    [Fact]
    public void Normalizer_SwapsReversedWeeklyAndUnknownWindows()
    {
        // Swift: swaps reversed weekly and unknown windows。
        var weekly = new CodexRateWindow(43, 10080, Now, null);
        var unknown = new CodexRateWindow(17, 540, Now, null);

        var (primary, secondary) = CodexRateWindowNormalizer.Normalize(weekly, unknown);

        Assert.Equal(17, primary!.UsedPercent);
        Assert.Equal(540, primary.WindowMinutes);
        Assert.Equal(43, secondary!.UsedPercent);
        Assert.Equal(10080, secondary.WindowMinutes);
    }

    [Fact]
    public void Normalizer_UnknownSecondaryOnlyWindowBecomesPrimary()
    {
        // Swift: preserves unknown secondary only window as primary。
        var unknown = new CodexRateWindow(17, 540, Now, null);

        var (primary, secondary) = CodexRateWindowNormalizer.Normalize(null, unknown);

        Assert.Equal(540, primary!.WindowMinutes);
        Assert.Null(secondary);
    }

    [Fact]
    public void Normalizer_SingleSessionWindowStaysPrimary()
    {
        // Swift: keeps single session window as primary。
        var session = new CodexRateWindow(9, 300, Now, null);

        var (primary, secondary) = CodexRateWindowNormalizer.Normalize(session, null);

        Assert.Equal(9, primary!.UsedPercent);
        Assert.Equal(300, primary.WindowMinutes);
        Assert.Null(secondary);
    }

    // ------------------------------------------------------------------
    // rate-limit-reset-credits-response.json
    // ------------------------------------------------------------------

    [Fact]
    public void RateLimitResetCredits_DecodesEmptyInventory()
    {
        var snapshot = CodexUsageParser.ParseRateLimitResetCredits(
            CodexFixtures.Read("rate-limit-reset-credits-response.json"), Now);

        Assert.Equal(0, snapshot.AvailableCount);
        Assert.Empty(snapshot.Credits);
        Assert.Empty(snapshot.AvailableCredits(Now));
    }

    [Fact]
    public void RateLimitResetCredits_RejectsNegativeAvailableCount()
    {
        // Swift: rejects negative available count。
        var json = CodexFixtures.Transform("rate-limit-reset-credits-response.json", root =>
        {
            root["available_count"] = -1;
        });

        Assert.Throws<CodexUsageParseException>(() =>
            CodexUsageParser.ParseRateLimitResetCredits(json, Now));
    }

    // ------------------------------------------------------------------
    // workspace-remaining-balance-response.json
    // ------------------------------------------------------------------

    [Fact]
    public void WorkspaceRemainingBalance_DecodesNumericBalance()
    {
        var balance = CodexUsageParser.ParseWorkspaceRemainingBalance(
            CodexFixtures.Read("workspace-remaining-balance-response.json"));

        Assert.Equal(1234, balance.Balance);
    }

    [Theory]
    [InlineData("NaN")]
    [InlineData("Infinity")]
    public void WorkspaceRemainingBalance_RejectsNonFiniteStringBalance(string raw)
    {
        // Swift: missing or invalid workspace balances retain the original result（balance
        // 为 "NaN"/"Infinity" → null，不得当作有效余额）。
        var json = CodexFixtures.Transform("workspace-remaining-balance-response.json", root =>
        {
            root["balance"] = raw;
        });

        var balance = CodexUsageParser.ParseWorkspaceRemainingBalance(json);

        Assert.Null(balance.Balance);
    }

    [Fact]
    public void WorkspaceRemainingBalance_MissingBalanceIsNull()
    {
        var json = CodexFixtures.Transform("workspace-remaining-balance-response.json", root =>
        {
            root["balance"] = null;
        });

        Assert.Null(CodexUsageParser.ParseWorkspaceRemainingBalance(json).Balance);
    }

    // ------------------------------------------------------------------
    // usage-snapshot-current.json
    // ------------------------------------------------------------------

    [Fact]
    public void UsageSnapshot_DecodesAppLayerWireShape()
    {
        var snapshot = CodexUsageParser.ParseUsageSnapshot(
            CodexFixtures.Read("usage-snapshot-current.json"));

        Assert.Equal(42, snapshot.Primary!.UsedPercent);
        Assert.Equal(300, snapshot.Primary!.WindowMinutes);
        Assert.Equal(new DateTimeOffset(2026, 8, 2, 17, 0, 0, TimeSpan.Zero), snapshot.Primary!.ResetsAt);
        Assert.Null(snapshot.Primary!.ResetDescription);
        Assert.Null(snapshot.Secondary);
        Assert.Null(snapshot.Tertiary);

        var cost = snapshot.ProviderCost!;
        Assert.Equal(12.5, cost.Used);
        Assert.Equal(50, cost.Limit);
        Assert.Equal("USD", cost.CurrencyCode);
        Assert.Equal("Monthly", cost.Period);
        Assert.Equal(new DateTimeOffset(2026, 8, 2, 12, 0, 0, TimeSpan.Zero), cost.UpdatedAt);

        Assert.Equal("synthetic", snapshot.Identity!.ProviderId);
        Assert.Equal("fixture@example.com", snapshot.Identity!.AccountEmail);
        Assert.Equal("Fixture Org", snapshot.Identity!.AccountOrganization);
        Assert.Equal("API key", snapshot.Identity!.LoginMethod);
        Assert.Equal("acct_fixture", snapshot.Identity!.AccountId);
        Assert.Equal(CodexDataConfidence.Exact, snapshot.DataConfidence);
        Assert.Equal(new DateTimeOffset(2026, 8, 2, 12, 0, 0, TimeSpan.Zero), snapshot.UpdatedAt);
    }

    [Fact]
    public void UsageSnapshot_MapsPrimaryWindowTo5hRow()
    {
        var snapshot = CodexUsageParser.ParseUsageSnapshot(
            CodexFixtures.Read("usage-snapshot-current.json"));

        var data = CodexUsageDataMapper.MapToUsageData(snapshot, credits: null, sourceLabel: "oauth", now: Now);

        var fiveHour = Assert.Single(data.Models);
        Assert.Equal("5h", fiveHour.ModelName);
        Assert.Equal(58, fiveHour.CurrentIntervalRemaining);
        Assert.Equal(58, fiveHour.CurrentIntervalRemainingPercent);
        Assert.Equal("fixture@example.com", fiveHour.AccountName);
        Assert.Equal("API Key · OAuth · resets 08/03 01:00", fiveHour.DetailText);
    }
}
