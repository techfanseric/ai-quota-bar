// Origin: mirrors the contract records ported from the Swift sources listed in each contract
// file header under windows/src/AIQuotaBar.Core/Contracts/.
//
// NOTE: 本机无 dotnet，待 CI/远程机首次运行（计划 §10：逻辑层测试跑在 macOS dotnet 或 CI）。
// These are construction + JSON round-trip smoke assertions pinning the camelCase wire format
// (Swift Codable key parity), NOT ported Swift behavior tests — those land with each Core task.

#nullable enable

using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Text.RegularExpressions;
using AIQuotaBar.Core.Contracts;
using Xunit;

namespace AIQuotaBar.Core.Tests.Contracts;

public sealed class ContractsSmokeTests
{
    private static readonly JsonSerializerOptions Json = QuotaJson.Default;

    private static readonly DateTimeOffset SampleTime =
        new(2026, 9, 24, 18, 30, 0, TimeSpan.FromHours(8));

    // ------------------------------------------------------------------ provider identity

    [Fact]
    public void UsageProvider_RawValues_MatchSwiftWireFormat()
    {
        Assert.Equal("minimax", UsageProvider.MiniMax.RawValue());
        Assert.Equal("glm", UsageProvider.Glm.RawValue());
        Assert.Equal("codex", UsageProvider.Codex.RawValue());
        Assert.Equal("kimi", UsageProvider.Kimi.RawValue());

        Assert.Equal(UsageProvider.Kimi, UsageProviders.FromRawValue("kimi"));
        Assert.Null(UsageProviders.FromRawValue("Codex")); // case-sensitive like Swift rawValue:
        Assert.Null(UsageProviders.FromRawValue(null));
    }

    [Fact]
    public void UsageProvider_CloudAlias_MapsChatGptToCodex()
    {
        // Swift UsageProvider.cloudProvider: trim + lowercase, legacy "chatgpt" -> codex.
        Assert.Equal(UsageProvider.Codex, UsageProviders.FromCloudRawValue(" ChatGPT "));
        Assert.Equal(UsageProvider.Codex, UsageProviders.FromCloudRawValue("CODEX"));
        Assert.Null(UsageProviders.FromCloudRawValue("openai"));
    }

    [Fact]
    public void UsageProvider_JsonUsesLowercaseSwiftRawValues()
    {
        // 应然：输出 Swift rawValue 小写形式（实然：C# 枚举名 "Codex" 则为失败）。
        Assert.Equal("\"codex\"", JsonSerializer.Serialize(UsageProvider.Codex, Json));
        Assert.Equal(UsageProvider.MiniMax, JsonSerializer.Deserialize<UsageProvider>("\"minimax\"", Json));
        Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<UsageProvider>("\"MiniMax\"", Json));
    }

    [Fact]
    public void QuotaIdentity_KeysFollowSwiftFormats()
    {
        // quotaIdentityKey: provider : normalizedAccount : normalizedModel (trimmed + lowercased).
        Assert.Equal(
            "codex:eric@x.com:5h",
            QuotaIdentity.Key(UsageProvider.Codex, "  Eric@X.COM ", " 5H "));
        Assert.Equal("glm:glm-4.6", QuotaIdentity.Key(UsageProvider.Glm, null, "GLM-4.6"));

        // id: provider : rawAccount : rawModel; account segment dropped when empty.
        Assert.Equal("codex:5h", QuotaIdentity.DisplayId(UsageProvider.Codex, null, "5h"));
        Assert.Equal("codex:5h", QuotaIdentity.DisplayId(UsageProvider.Codex, "", "5h"));
        Assert.Equal("codex:a@b.c:Weekly", QuotaIdentity.DisplayId(UsageProvider.Codex, "a@b.c", "Weekly"));
    }

    // ------------------------------------------------------------------ quota window

    [Fact]
    public void QuotaWindow_RoundTrip_UsesCamelCaseKind()
    {
        var window = new QuotaWindow(
            Start: SampleTime,
            End: SampleTime.AddHours(5),
            Kind: QuotaWindowKind.MonthlyTotal);

        var json = JsonSerializer.Serialize(window, Json);
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        Assert.Equal("monthlyTotal", root.GetProperty("kind").GetString());
        Assert.Equal(5, window.Duration!.Value.TotalHours, precision: 3);
        Assert.True(window.Contains(SampleTime.AddHours(1)));
        Assert.False(window.Contains(SampleTime.AddHours(6)));

        Assert.Equal(window, JsonSerializer.Deserialize<QuotaWindow>(json, Json));
    }

    [Fact]
    public void QuotaWindow_OpenEnded_HasNoDuration()
    {
        var window = new QuotaWindow(Start: null, End: SampleTime, Kind: QuotaWindowKind.MonthlyTotal);
        Assert.Null(window.Duration);
        Assert.True(window.Contains(SampleTime.AddHours(-1)));
    }

    // ------------------------------------------------------------------ model usage data

    private static ModelUsageData MakeCodexFiveHourRow() => new(
        Provider: UsageProvider.Codex,
        AccountName: "user@example.com",
        ModelName: "5h",
        CurrentIntervalTotal: 100,
        CurrentIntervalRemaining: 64, // Swift: currentIntervalUsed — wire key must stay "currentIntervalUsed"
        WeeklyTotal: 0,
        WeeklyRemaining: 0,
        RemainsTimeMilliseconds: 3_600_000,
        StartTime: SampleTime.AddHours(-1.5),
        EndTime: SampleTime.AddHours(1),
        WeeklyStartTime: null,
        WeeklyEndTime: null,
        ValueSuffix: "%",
        DetailText: "Pro 20x · OAuth · resets 09/24 19:30",
        CurrentIntervalRemainingPercent: 64,
        WeeklyRemainingPercent: null,
        ProgressBarPercentOverride: null,
        ProgressBarRightText: null,
        SampledAt: null);

    [Fact]
    public void ModelUsageData_RoundTrip_PreservesSwiftWireKeys()
    {
        var row = MakeCodexFiveHourRow();

        var json = JsonSerializer.Serialize(row, Json);
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        // camelCase Swift Codable keys.
        Assert.Equal("codex", root.GetProperty("provider").GetString());
        Assert.Equal("user@example.com", root.GetProperty("accountName").GetString());
        Assert.Equal(100, root.GetProperty("currentIntervalTotal").GetInt32());
        // 应然：重命名的 CurrentIntervalRemaining 仍以 Swift 键 currentIntervalUsed 上线（实然：缺失或值错）。
        Assert.Equal(64, root.GetProperty("currentIntervalUsed").GetInt32());
        Assert.Equal(64, root.GetProperty("currentIntervalRemainingPercent").GetInt32());
        Assert.Equal(3_600_000, root.GetProperty("remainsTime").GetInt32());
        Assert.Equal("%", root.GetProperty("valueSuffix").GetString());
        Assert.True(root.TryGetProperty("startTime", out _), "应存在 camelCase 键 startTime");

        // Null optionals are omitted (Swift encodeIfPresent semantics).
        Assert.False(root.TryGetProperty("weeklyRemainingPercent", out _));
        Assert.False(root.TryGetProperty("progressBarPercentOverride", out _));
        Assert.False(root.TryGetProperty("sampledAt", out _));

        var restored = JsonSerializer.Deserialize<ModelUsageData>(json, Json);
        Assert.Equal(row, restored);
    }

    [Fact]
    public void ModelUsageData_CreditsRow_RoundTrip()
    {
        var row = new ModelUsageData(
            Provider: UsageProvider.Codex,
            AccountName: null,
            ModelName: "Credits",
            CurrentIntervalTotal: 1000,
            CurrentIntervalRemaining: 420,
            WeeklyTotal: 0,
            WeeklyRemaining: 0,
            RemainsTimeMilliseconds: 0,
            StartTime: null,
            EndTime: null,
            WeeklyStartTime: null,
            WeeklyEndTime: null,
            ValueSuffix: " left",
            DetailText: null,
            CurrentIntervalRemainingPercent: null,
            WeeklyRemainingPercent: null,
            ProgressBarPercentOverride: 42.0,
            ProgressBarRightText: "1K tokens",
            SampledAt: null);

        var json = JsonSerializer.Serialize(row, Json);
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        Assert.Equal(1000, root.GetProperty("currentIntervalTotal").GetInt32());
        Assert.Equal(420, root.GetProperty("currentIntervalUsed").GetInt32());
        Assert.Equal(42.0, root.GetProperty("progressBarPercentOverride").GetDouble(), precision: 6);
        Assert.Equal("1K tokens", root.GetProperty("progressBarRightText").GetString());
        Assert.False(root.TryGetProperty("accountName", out _)); // null omitted
        Assert.False(root.TryGetProperty("startTime", out _));

        Assert.Equal(row, JsonSerializer.Deserialize<ModelUsageData>(json, Json));
    }

    // ------------------------------------------------------------------ usage data

    [Fact]
    public void UsageData_RoundTrip_KeepsNestedModelsAndGlmAllowances()
    {
        var usage = new UsageData(
            Provider: UsageProvider.Glm,
            Remains: 1,
            Total: 2,
            Timestamp: SampleTime,
            Models: new ModelUsageData[]
            {
                MakeCodexFiveHourRow() with { Provider = UsageProvider.Glm, ModelName = "GLM-4.6 5h" },
            },
            SubscribeTitle: null,
            SubscribeEndTime: null,
            GlmResetAllowances: new GlmResetAllowances(
                FiveHourExpirations: new[] { SampleTime.AddHours(2), SampleTime.AddHours(7) },
                WeeklyExpirations: new[] { SampleTime.AddDays(3) }));

        var json = JsonSerializer.Serialize(usage, Json);
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        Assert.Equal("glm", root.GetProperty("provider").GetString());
        Assert.Equal(2, root.GetProperty("total").GetInt32());
        Assert.False(root.TryGetProperty("subscribeTitle", out _)); // null omitted
        var allowances = root.GetProperty("glmResetAllowances");
        Assert.Equal(2, allowances.GetProperty("fiveHourExpirations").GetArrayLength());

        var restored = JsonSerializer.Deserialize<UsageData>(json, Json);
        Assert.NotNull(restored);
        Assert.Equal(usage.Provider, restored.Provider);
        Assert.Equal(usage.Remains, restored.Remains);
        Assert.Equal(usage.Total, restored.Total);
        Assert.Equal(usage.Timestamp, restored.Timestamp);
        Assert.Equal(usage.Models, restored.Models);
        Assert.Null(restored.SubscribeTitle);
        Assert.Null(restored.SubscribeEndTime);
        Assert.Equal(
            allowances.GetProperty("fiveHourExpirations").GetArrayLength(),
            restored.GlmResetAllowances!.FiveHourExpirations.Count);
    }

    // ------------------------------------------------------------------ forecast shapes

    [Fact]
    public void ModelQuotaSample_And_Forecast_RoundTrip()
    {
        var sample = new ModelQuotaSample(SampleTime, Remaining: 64, Percent: null);
        var sampleJson = JsonSerializer.Serialize(sample, Json);
        using (var doc = JsonDocument.Parse(sampleJson))
        {
            Assert.False(doc.RootElement.TryGetProperty("percent", out _)); // null omitted
        }

        Assert.Equal(sample, JsonSerializer.Deserialize<ModelQuotaSample>(sampleJson, Json));

        var forecast = new QuotaConsumptionForecast(
            LookbackIntervals: 2,
            ConsumptionPerSecond: 0.0125,
            StartsAt: SampleTime,
            StartingRemaining: 64,
            ExhaustsAt: SampleTime.AddHours(2));
        var forecastJson = JsonSerializer.Serialize(forecast, Json);
        using (var doc = JsonDocument.Parse(forecastJson))
        {
            var root = doc.RootElement;
            Assert.Equal(2, root.GetProperty("lookbackIntervals").GetInt32());
            Assert.Equal(0.0125, root.GetProperty("consumptionPerSecond").GetDouble(), precision: 9);
            Assert.True(root.TryGetProperty("startingRemaining", out _));
            Assert.True(root.TryGetProperty("exhaustsAt", out _));
        }

        Assert.Equal(forecast, JsonSerializer.Deserialize<QuotaConsumptionForecast>(forecastJson, Json));
    }

    [Fact]
    public void QuotaForecastRequest_OptionalGap_OmittedWhenNull()
    {
        var withoutGap = new QuotaForecastRequest(
            Samples: new[] { new ModelQuotaSample(SampleTime, 64, null) },
            IsPercentMode: true,
            MaximumLookbackIntervals: 3,
            MaximumSampleGap: null);
        var json = JsonSerializer.Serialize(withoutGap, Json);
        using (var doc = JsonDocument.Parse(json))
        {
            Assert.True(doc.RootElement.TryGetProperty("isPercentMode", out _));
            Assert.False(doc.RootElement.TryGetProperty("maximumSampleGap", out _));
        }

        var withGap = withoutGap with { MaximumSampleGap = TimeSpan.FromSeconds(180) };
        var jsonWithGap = JsonSerializer.Serialize(withGap, Json);
        using (var doc = JsonDocument.Parse(jsonWithGap))
        {
            Assert.True(doc.RootElement.TryGetProperty("maximumSampleGap", out _));
        }

        var restored = JsonSerializer.Deserialize<QuotaForecastRequest>(jsonWithGap, Json);
        Assert.NotNull(restored);
        Assert.Equal(TimeSpan.FromSeconds(180), restored.MaximumSampleGap);
        Assert.Equal(withoutGap.Samples, restored.Samples);
        Assert.True(restored.IsPercentMode);
        Assert.Equal(3, restored.MaximumLookbackIntervals);
    }

    // ------------------------------------------------------------------ utilization history

    [Fact]
    public void UtilizationHistoryMode_JsonUsesSwiftRawValues()
    {
        Assert.Equal("\"includeCurrent\"", JsonSerializer.Serialize(UtilizationHistoryMode.IncludeCurrent, Json));
        Assert.Equal(
            UtilizationHistoryMode.CompletedOnly,
            JsonSerializer.Deserialize<UtilizationHistoryMode>("\"completedOnly\"", Json));
    }

    [Fact]
    public void ModelUtilizationHistory_RoundTrip()
    {
        var history = new ModelUtilizationHistory(
            ModelId: "codex:user@example.com:5h",
            Entries: new[]
            {
                new UtilizationHistoryEntry(SampleTime.AddHours(-2), 35.0, SampleTime.AddHours(1)),
                new UtilizationHistoryEntry(SampleTime.AddHours(-1), 48.5, SampleTime.AddHours(1)),
            });

        var json = JsonSerializer.Serialize(history, Json);
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        Assert.Equal("codex:user@example.com:5h", root.GetProperty("modelId").GetString());
        Assert.Equal(2, root.GetProperty("entries").GetArrayLength());
        Assert.Equal(48.5, root.GetProperty("entries")[1].GetProperty("usedPercent").GetDouble(), precision: 3);

        var restored = JsonSerializer.Deserialize<ModelUtilizationHistory>(json, Json);
        Assert.NotNull(restored);
        Assert.Equal(history.ModelId, restored.ModelId);
        Assert.Equal(history.Entries, restored.Entries);
        Assert.Equal(2200, ModelUtilizationHistory.MaxEntriesPerModel);
        Assert.Equal(120, ModelUtilizationHistory.ResetBoundaryMergeToleranceSeconds);
    }

    [Fact]
    public void ModelUtilizationStoreData_ToleratesLegacyMissingHistories()
    {
        var restored = JsonSerializer.Deserialize<ModelUtilizationStoreData>("{}", Json);
        Assert.NotNull(restored);
        Assert.Null(restored.Histories); // Swift: old files without the field decode to nil
    }

    // ------------------------------------------------------------------ GLM allowances

    [Fact]
    public void GlmResetAllowances_RoundTrip()
    {
        var allowances = new GlmResetAllowances(
            FiveHourExpirations: new[] { SampleTime.AddHours(2) },
            WeeklyExpirations: Array.Empty<DateTimeOffset>());

        var json = JsonSerializer.Serialize(allowances, Json);
        using var doc = JsonDocument.Parse(json);
        Assert.Equal(1, doc.RootElement.GetProperty("fiveHourExpirations").GetArrayLength());
        Assert.Equal(0, doc.RootElement.GetProperty("weeklyExpirations").GetArrayLength());

        var restored = JsonSerializer.Deserialize<GlmResetAllowances>(json, Json);
        Assert.NotNull(restored);
        Assert.Equal(allowances.FiveHourExpirations, restored.FiveHourExpirations);
        Assert.Empty(restored.WeeklyExpirations);
    }

    // ------------------------------------------------------------------ data report snapshot

    [Fact]
    public void DataReportSnapshot_RoundTrip_MatchesSwiftEnumDictionaryEncoding()
    {
        var snapshot = new DataReportSnapshot(
            GeneratedAt: SampleTime,
            UsageData: null,
            ProviderUsageData: new[]
            {
                new ProviderUsageDataEntry(
                    UsageProvider.Codex,
                    new UsageData(
                        Provider: UsageProvider.Codex,
                        Remains: 1,
                        Total: 1,
                        Timestamp: SampleTime,
                        Models: new[] { MakeCodexFiveHourRow() },
                        SubscribeTitle: null,
                        SubscribeEndTime: null,
                        GlmResetAllowances: null)),
            },
            ModelQuotaSamples: new Dictionary<string, IReadOnlyList<ModelQuotaSample>>
            {
                ["codex:user@example.com:5h"] = new[] { new ModelQuotaSample(SampleTime, 64, null) },
            },
            UtilizationHistories: new[]
            {
                new ProviderUtilizationHistoriesEntry(
                    UsageProvider.Codex,
                    new ModelUtilizationStoreData(Histories: new Dictionary<string, ModelUtilizationHistory>())),
            });

        var json = JsonSerializer.Serialize(snapshot, Json);
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        // Swift Dictionary<UsageProvider, T> encodes as [{ "key": "codex", "value": {...} }].
        var providerEntry = root.GetProperty("providerUsageData")[0];
        // 应然：枚举键应编码为 { key, value } 数组元素（实然：对象键或其他形状则失败）。
        Assert.Equal("codex", providerEntry.GetProperty("key").GetString());
        Assert.Equal(1, providerEntry.GetProperty("value").GetProperty("remains").GetInt32());

        // String-keyed dictionaries stay JSON objects.
        Assert.True(root.GetProperty("modelQuotaSamples").TryGetProperty("codex:user@example.com:5h", out _));
        Assert.False(root.TryGetProperty("usageData", out _)); // null omitted

        var restored = JsonSerializer.Deserialize<DataReportSnapshot>(json, Json);
        Assert.NotNull(restored);
        Assert.Equal(snapshot.GeneratedAt, restored.GeneratedAt);
        Assert.Null(restored.UsageData);
        var entry = Assert.Single(restored.ProviderUsageData);
        Assert.Equal(UsageProvider.Codex, entry.Key);
        Assert.Equal(snapshot.ProviderUsageData[0].Value.Models, entry.Value.Models);
        Assert.Equal(
            snapshot.ModelQuotaSamples["codex:user@example.com:5h"],
            restored.ModelQuotaSamples["codex:user@example.com:5h"]);
        Assert.Empty(Assert.Single(restored.UtilizationHistories).Value.Histories!);
    }

    // ------------------------------------------------------------------ strict Swift iso8601 dates

    [Fact]
    public void DateTimeOffsetFields_Serialize_AsStrictUtcSecondPrecisionIso8601()
    {
        // 输入带 +08:00 偏移：应然输出恒 UTC、"Z" 后缀、秒精度（差分金标测试的前提）。
        var sample = new ModelQuotaSample(
            new DateTimeOffset(2026, 9, 24, 18, 30, 0, TimeSpan.FromHours(8)),
            Remaining: 64,
            Percent: null);

        var json = JsonSerializer.Serialize(sample, Json);
        using var doc = JsonDocument.Parse(json);
        var text = doc.RootElement.GetProperty("timestamp").GetString();

        Assert.NotNull(text);
        // 应然：+08:00 18:30 → "2026-09-24T10:30:00Z"（精确文本，非仅语义等价）。
        Assert.Equal("2026-09-24T10:30:00Z", text);
        // 形状：yyyy-MM-ddTHH:mm:ssZ，无小数秒。
        Assert.True(
            Regex.IsMatch(text!, @"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"),
            $"日期形状应为 yyyy-MM-ddTHH:mm:ssZ（实然：{text}）");

        // 亚秒精度在写入时截断（Swift .iso8601 对 fractional Date 的行为一致）。
        var fractional = sample with { Timestamp = sample.Timestamp.AddMilliseconds(250) };
        var fractionalJson = JsonSerializer.Serialize(fractional, Json);
        using var fractionalDoc = JsonDocument.Parse(fractionalJson);
        Assert.Equal(
            "2026-09-24T10:30:00Z",
            fractionalDoc.RootElement.GetProperty("timestamp").GetString());

        // 可空 DateTimeOffset? 字段同样走严格形状（ModelUsageData.EndTime = SampleTime + 1h → 11:30Z）。
        var rowJson = JsonSerializer.Serialize(MakeCodexFiveHourRow(), Json);
        using var rowDoc = JsonDocument.Parse(rowJson);
        Assert.Equal("2026-09-24T11:30:00Z", rowDoc.RootElement.GetProperty("endTime").GetString());

        // 顶层可空值：非 null 走严格形状，null 原样输出。
        Assert.Equal("\"2026-09-24T10:30:00Z\"", JsonSerializer.Serialize<DateTimeOffset?>(SampleTime, Json));
        Assert.Equal("null", JsonSerializer.Serialize<DateTimeOffset?>(null, Json));
    }

    [Fact]
    public void DateTimeOffsetFields_RoundTrip_ValueEqualAndSerializationIdempotent()
    {
        var sample = new ModelQuotaSample(
            new DateTimeOffset(2026, 9, 24, 18, 30, 0, TimeSpan.FromHours(8)),
            Remaining: 64,
            Percent: null);

        // 非 Z 偏移读入后规范化为 UTC（瞬时值等价：+08:00 18:30 == 10:30Z）。
        var withOffset = JsonSerializer.Deserialize<ModelQuotaSample>(
            "{\"timestamp\":\"2026-09-24T18:30:00+08:00\",\"remaining\":64}", Json);
        Assert.NotNull(withOffset);
        Assert.Equal(sample.Timestamp, withOffset.Timestamp);
        Assert.Equal(TimeSpan.Zero, withOffset.Timestamp.Offset);

        // round-trip 值等价 + 再序列化幂等（byte-equal）。
        var first = JsonSerializer.Serialize(sample, Json);
        var restored = JsonSerializer.Deserialize<ModelQuotaSample>(first, Json);
        Assert.NotNull(restored);
        Assert.Equal(sample.Timestamp, restored.Timestamp);
        var second = JsonSerializer.Serialize(restored, Json);
        Assert.Equal(first, second);
    }
}
