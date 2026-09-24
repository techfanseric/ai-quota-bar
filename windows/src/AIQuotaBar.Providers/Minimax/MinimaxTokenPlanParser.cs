// Swift 来源（映射层）：AIQuotaBar/Services/UsageService.swift — decodeMiniMaxUsageData(from:subscribe:)
// 与 date(fromMilliseconds:)；模型行 DTO MiniMaxUsageAPIResponse / MiniMaxModelRemain /
// MiniMaxBaseResponse / MiniMaxCurrentSubscribe 见 AIQuotaBar/Models/UsageData.swift:603-692。
// Swift 来源（容错解码契约基准）：.dependencies/codexbar/Sources/CodexBarCore/Providers/MiniMax/
// MiniMaxUsageFetcher.swift（MiniMaxCodingPlanPayload：data 缺失时按顶层负载解码；data.base_resp 与
// 顶层 base_resp 二选一）与 MiniMaxDecoding.swift（decodeInt/decodeDouble：数字 / 数字字符串双形态，
// 字符串先 trim）。
// 对应测试：windows/contracts/fixtures/minimax/*.json（断言依据 codexbar
// ProviderQuotaFixtureContractTests.swift:8-41）；字段语义权威文档：docs/api-field-mapping.md ——
// 所有 _usage_count 字段是剩余数量而非已用（current_interval_usage_count = 当前周期剩余）。

using System.Globalization;
using System.Text.Json;
using AIQuotaBar.Core.Contracts;

namespace AIQuotaBar.Providers.Minimax;

/// <summary>
/// MiniMax token-plan / coding-plan remains 响应解析（macOS: UsageService.decodeMiniMaxUsageData +
/// codexbar: MiniMaxUsageParser.parseCodingPlanRemains 的解码前置）。纯函数、无 I/O。
/// </summary>
public static class MinimaxTokenPlanParser
{
    /// <param name="now">取样时刻（Swift: Date()）；测试注入。</param>
    public static UsageData Parse(string json, DateTimeOffset? now = null)
    {
        var at = now ?? DateTimeOffset.UtcNow;
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                throw new JsonException("MiniMax 响应不是 JSON 对象。");
            }

            // codexbar MiniMaxCodingPlanPayload：有 "data" 对象则取之，否则整个负载按 data 解码。
            var data = root.TryGetProperty("data", out var dataElement)
                && dataElement.ValueKind == JsonValueKind.Object
                    ? dataElement
                    : root;

            // codexbar: payload.data.baseResp ?? payload.baseResp —— data 上的 base_resp 优先，
            // 顶层兜底。值类型 JsonElement 与 null 不能落在 var 三元里（CS0173），改为显式语句。
            JsonElement? baseResp;
            if (TryPropertyObject(data, "base_resp", out var nested))
            {
                baseResp = nested;
            }
            else if (TryPropertyObject(root, "base_resp", out var topLevel))
            {
                baseResp = topLevel;
            }
            else
            {
                baseResp = null;
            }
            if (baseResp is { } response && FlexibleOptionalInt32(response, "status_code") is int statusCode
                && statusCode != 0)
            {
                var message = OptionalString(response, "status_msg") ?? $"status_code {statusCode}";
                var lowered = message.ToLowerInvariant();
                if (statusCode == 1004
                    || lowered.Contains("cookie", StringComparison.Ordinal)
                    || lowered.Contains("log in", StringComparison.Ordinal)
                    || lowered.Contains("login", StringComparison.Ordinal))
                {
                    throw new MinimaxUsageException(MinimaxUsageErrorKind.InvalidCredentials, message);
                }
                throw new MinimaxUsageException(MinimaxUsageErrorKind.ApiError, message);
            }

            var models = new List<ModelUsageData>();
            if (data.TryGetProperty("model_remains", out var modelRemains)
                && modelRemains.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in modelRemains.EnumerateArray())
                {
                    if (item.ValueKind != JsonValueKind.Object)
                    {
                        throw new JsonException("MiniMax model_remains 含非对象元素。");
                    }
                    // macOS 端 model_name 为非可选 String：缺失即解码失败。
                    var modelName = RequiredString(item, "model_name");
                    models.Add(new ModelUsageData(
                        UsageProvider.MiniMax,
                        AccountName: null,
                        ModelName: modelName,
                        CurrentIntervalTotal: FlexibleOptionalInt32(item, "current_interval_total_count") ?? 0,
                        // _usage_count = 剩余数量（不是已用！）。契约字段 currentIntervalUsed 语义即剩余。
                        CurrentIntervalRemaining: FlexibleOptionalInt32(item, "current_interval_usage_count") ?? 0,
                        WeeklyTotal: FlexibleOptionalInt32(item, "current_weekly_total_count") ?? 0,
                        WeeklyRemaining: FlexibleOptionalInt32(item, "current_weekly_usage_count") ?? 0,
                        RemainsTimeMilliseconds: ClampInt32(FlexibleOptionalInt64(item, "remains_time") ?? 0),
                        StartTime: DateFromMilliseconds(FlexibleOptionalInt64(item, "start_time")),
                        EndTime: DateFromMilliseconds(FlexibleOptionalInt64(item, "end_time")),
                        WeeklyStartTime: DateFromMilliseconds(FlexibleOptionalInt64(item, "weekly_start_time")),
                        WeeklyEndTime: DateFromMilliseconds(FlexibleOptionalInt64(item, "weekly_end_time")),
                        ValueSuffix: null,
                        DetailText: null,
                        CurrentIntervalRemainingPercent: FlexibleRemainingPercent(item, "current_interval_remaining_percent"),
                        WeeklyRemainingPercent: FlexibleRemainingPercent(item, "current_weekly_remaining_percent"),
                        ProgressBarPercentOverride: null,
                        ProgressBarRightText: null,
                        SampledAt: null));
                }
            }
            if (models.Count == 0)
            {
                // codexbar parseFailed "Missing coding plan data."
                throw new MinimaxUsageException(
                    MinimaxUsageErrorKind.InvalidResponse, "MiniMax 响应缺少 coding plan 数据（model_remains 为空）。");
            }

            var remains = models.Count(IsCurrentIntervalAvailable);
            var subscribeTitle = TrimmedOrNull(OptionalString(data, "current_subscribe_title"));
            var subscribeEndMilliseconds = FlexibleOptionalInt64(data, "current_subscribe_end_time_ts");
            DateTimeOffset? subscribeEndTime = subscribeEndMilliseconds is > 0
                ? DateTimeOffset.FromUnixTimeMilliseconds(subscribeEndMilliseconds.Value)
                : null;
            return new UsageData(
                UsageProvider.MiniMax,
                remains,
                Math.Max(models.Count, 1),
                at,
                models,
                subscribeTitle,
                subscribeEndTime,
                GlmResetAllowances: null);
        }
        catch (JsonException ex)
        {
            throw new MinimaxUsageException(
                MinimaxUsageErrorKind.InvalidResponse, "MiniMax 响应不是合法的 token-plan JSON 负载。", ex);
        }
    }

    /// <summary>Swift: models.filter(\.isCurrentIntervalAvailable)；remains 是“仍有额度的模型数”。</summary>
    private static bool IsCurrentIntervalAvailable(ModelUsageData model) =>
        model.CurrentIntervalRemainingPercent is int percent ? percent > 0 : model.CurrentIntervalRemaining > 0;

    /// <summary>Swift: date(fromMilliseconds:) —— 0/负值/缺失返回 null。</summary>
    private static DateTimeOffset? DateFromMilliseconds(long? value) =>
        value is > 0 ? DateTimeOffset.FromUnixTimeMilliseconds(value.Value) : null;

    private static string? TrimmedOrNull(string? value)
    {
        var trimmed = value?.Trim();
        return string.IsNullOrEmpty(trimmed) ? null : trimmed;
    }

    private static int ClampInt32(long value) =>
        value < 0 ? 0 : value > int.MaxValue ? int.MaxValue : (int)value;

    // ------------------------------------------------------------------
    // 容错解码（codexbar MiniMaxDecoding.decodeInt/decodeDouble：数字 / Int64 / Double / 字符串，字符串先 trim）。
    // ------------------------------------------------------------------

    private static bool TryPropertyObject(JsonElement element, string name, out JsonElement value)
    {
        value = default;
        return element.ValueKind == JsonValueKind.Object
            && element.TryGetProperty(name, out value)
            && value.ValueKind == JsonValueKind.Object;
    }

    private static int? FlexibleOptionalInt32(JsonElement element, string name)
    {
        var value = FlexibleOptionalInt64(element, name);
        return value is null ? null : ClampInt32Loose(value.Value);
    }

    private static long? FlexibleOptionalInt64(JsonElement element, string name)
    {
        if (element.ValueKind != JsonValueKind.Object || !element.TryGetProperty(name, out var value))
        {
            return null;
        }
        if (value.ValueKind == JsonValueKind.Number)
        {
            if (value.TryGetInt64(out var parsed))
            {
                return parsed;
            }
            if (value.TryGetDouble(out var doubleParsed))
            {
                return (long)doubleParsed; // codexbar: Int(Double) 截断
            }
            return null;
        }
        if (value.ValueKind == JsonValueKind.String)
        {
            var trimmed = (value.GetString() ?? string.Empty).Trim();
            return long.TryParse(trimmed, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsedString)
                ? parsedString
                : null;
        }
        return null;
    }

    /// <summary>百分比字段（"96" / 75 双形态）→ 契约 int?（0-100 剩余百分比，MiniMax 直给）。</summary>
    private static int? FlexibleRemainingPercent(JsonElement element, string name)
    {
        if (element.ValueKind != JsonValueKind.Object || !element.TryGetProperty(name, out var value))
        {
            return null;
        }
        double? parsed = value.ValueKind switch
        {
            JsonValueKind.Number when value.TryGetDouble(out var number) => number,
            JsonValueKind.String when double.TryParse(
                (value.GetString() ?? string.Empty).Trim(),
                NumberStyles.Float,
                CultureInfo.InvariantCulture,
                out var text) => text,
            _ => null,
        };
        if (parsed is not { } percent)
        {
            return null;
        }
        // 百分比原样透传（macOS 直拷 API 值）；舍入对齐 Swift Int(Double) 的半数远离零。
        var rounded = (int)Math.Round(percent, MidpointRounding.AwayFromZero);
        return rounded < 0 ? 0 : rounded;
    }

    private static string? OptionalString(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object
            && element.TryGetProperty(name, out var value)
            && value.ValueKind == JsonValueKind.String
                ? value.GetString()
                : null;

    private static string RequiredString(JsonElement element, string name)
    {
        if (element.ValueKind == JsonValueKind.Object
            && element.TryGetProperty(name, out var value)
            && value.ValueKind == JsonValueKind.String)
        {
            return value.GetString() ?? string.Empty;
        }
        throw new JsonException($"MiniMax 字段 '{name}' 缺失或不是字符串。");
    }

    /// <summary>计数字段超 int 范围时钳到边界（Swift Int 64 位；现实负载远小于 int 上限）。</summary>
    private static int? ClampInt32Loose(long value) =>
        value < 0 ? 0 : value > int.MaxValue ? int.MaxValue : (int?)value;
}
