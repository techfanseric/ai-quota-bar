// Swift 来源：AIQuotaBar/Services/UsageService.swift — decodeGLMUsageData(from:subscriptionResetTime:) 与其
// 私有映射辅助 glmModel(from:subscriptionResetTime:)、normalizedGLMQuotaValues(for:)、glmModelName(for:)、
// glmDetailText(for:used:total:)、glmPeriodText(unit:number:fallback:)、glmWindowDuration(for:)、
// date(fromMilliseconds:)、isCurrentIntervalAvailable（Models/UsageData.swift:252）。
// 响应 DTO（GLMQuotaLimitResponse / GLMQuotaLimitData / GLMUsageLimitItem / GLMUsageDetailItem）与
// decodeFlexible* 容错解码：AIQuotaBar/Models/UsageData.swift:694-848。
// 对应测试：AIQuotaBar/Tests/GLM/GLMUsageTests.swift（fixtures 驱动：windows/contracts/fixtures/glm/*.json）。
// 字段语义权威文档：docs/glm-api-field-mapping.md（usage=总额度、currentValue=已用、remaining=服务端剩余
// 优先采用、percentage=已用百分比、nextResetTime=毫秒时间戳可缺失、unit/number 周期编码 1d/3h/5m/6w）。

using System.Globalization;
using System.Text.Json;
using AIQuotaBar.Core.Contracts;

namespace AIQuotaBar.Providers.Glm;

/// <summary>
/// GLM quota/limit 响应解析（Swift: UsageService.decodeGLMUsageData）。纯函数、无 I/O；
/// 字段兼容数字/字符串双形态（Swift decodeFlexible*），缺周期字段的 TOKENS_LIMIT 按旧版 5h 窗口处理。
/// </summary>
public static class GlmQuotaParser
{
    private const string CreditLimitType = "CREDIT_LIMIT";
    private const string TokensLimitType = "TOKENS_LIMIT";
    private const string TimeLimitType = "TIME_LIMIT";

    // Swift Double(Int.max)：usage.rounded() 小于该值才允许走计数模式（防 Int 溢出）。
    private const double Int64LimitAsDouble = 9.2233720368547758E18;

    /// <param name="subscriptionResetTime">旧版 TIME_LIMIT 缺 nextResetTime 时的订阅续期兜底（Swift 同名参数）。</param>
    /// <param name="now">取样时刻（Swift: Date()），决定 Timestamp 与 RemainsTimeMilliseconds；测试注入。</param>
    public static UsageData Parse(string json, DateTimeOffset? subscriptionResetTime = null, DateTimeOffset? now = null)
    {
        var at = now ?? DateTimeOffset.UtcNow;
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;

            var code = RequiredInt32(root, "code");
            var success = RequiredBoolean(root, "success");
            if (!success || code != 200)
            {
                throw new GlmUsageException(
                    GlmUsageErrorKind.ApiError,
                    OptionalString(root, "msg") ?? "Unknown error");
            }

            string? level = null;
            var limitItems = Array.Empty<JsonElement>();
            if (TryProperty(root, "data", out var data) && data.ValueKind == JsonValueKind.Object)
            {
                // Swift：data?.limits（data 存在时 limits 为必填数组，缺键即解码失败）。
                if (!TryProperty(data, "limits", out var limits) || limits.ValueKind != JsonValueKind.Array)
                {
                    throw new JsonException("GLM 响应 data.limits 缺失或不是数组。");
                }
                limitItems = limits.EnumerateArray().ToArray();
                level = OptionalString(data, "level");
            }

            var models = new List<ModelUsageData>();
            foreach (var item in limitItems)
            {
                var model = ModelFrom(item, subscriptionResetTime, at);
                if (model is not null)
                {
                    models.Add(model);
                }
            }
            if (models.Count == 0)
            {
                // 空额度 / 不可用额度数据返回错误，避免“连接成功但没有数据”。
                throw new GlmUsageException(
                    GlmUsageErrorKind.InvalidResponse,
                    "GLM 响应未包含可用额度条目（空 limits 或条目缺数值字段）。");
            }

            var remains = models.Count(IsCurrentIntervalAvailable);
            return new UsageData(
                UsageProvider.Glm,
                remains,
                models.Count,
                at,
                models,
                level,
                SubscribeEndTime: null,
                GlmResetAllowances: null);
        }
        catch (JsonException ex)
        {
            throw new GlmUsageException(
                GlmUsageErrorKind.InvalidResponse, "GLM 响应不是合法的配额 JSON 负载。", ex);
        }
    }

    /// <summary>
    /// Swift fetchGLMUsage 的辅助判定：仅当成功负载里存在缺 nextResetTime 的 TIME_LIMIT 条目时，
    /// 才需要旧版 /api/biz/subscription/list 兜底（docs/glm-api-field-mapping.md:60）。
    /// </summary>
    public static bool RequiresLegacySubscriptionReset(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (!TryProperty(root, "data", out var data) || data.ValueKind != JsonValueKind.Object)
            {
                return false;
            }
            if (!TryProperty(data, "limits", out var limits) || limits.ValueKind != JsonValueKind.Array)
            {
                return false;
            }
            foreach (var item in limits.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }
                if (OptionalString(item, "type") == TimeLimitType
                    && FlexibleOptionalInt64(item, "nextResetTime") is null)
                {
                    return true;
                }
            }
            return false;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    /// <summary>Swift: models.filter(\.isCurrentIntervalAvailable) — 百分比模式看 percent>0，否则看剩余计数。</summary>
    private static bool IsCurrentIntervalAvailable(ModelUsageData model) =>
        model.CurrentIntervalRemainingPercent is int percent ? percent > 0 : model.CurrentIntervalRemaining > 0;

    private static ModelUsageData? ModelFrom(
        JsonElement item,
        DateTimeOffset? subscriptionResetTime,
        DateTimeOffset at)
    {
        var type = FlexibleString(item, "type");
        var currentValue = FlexibleDouble(item, "currentValue");
        var usage = FlexibleDouble(item, "usage");
        var percentage = FlexibleOptionalDouble(item, "percentage");
        var nextResetTime = FlexibleOptionalInt64(item, "nextResetTime");
        var remaining = FlexibleOptionalDouble(item, "remaining");
        var unit = FlexibleOptionalInt64(item, "unit");
        var number = FlexibleOptionalInt64(item, "number");
        var usageDetails = FlexibleUsageDetails(item);

        var normalized = NormalizeQuotaValues(usage, currentValue, remaining, percentage);
        if (normalized.Total <= 0)
        {
            return null;
        }

        // nextResetTime 可缺失；缺失时不伪造周期起止时间（5h 窗口无 reset 时 start/end 均为 null）。
        DateTimeOffset? endTime = nextResetTime is > 0
            ? DateTimeOffset.FromUnixTimeMilliseconds(nextResetTime.Value)
            : null;
        if (endTime is null && type == TimeLimitType)
        {
            endTime = subscriptionResetTime;
        }

        var duration = WindowDuration(type, unit, number);
        DateTimeOffset? startTime = endTime is not null && duration is not null
            ? endTime.Value - duration.Value
            : null;

        return new ModelUsageData(
            UsageProvider.Glm,
            AccountName: null,
            ModelName: ModelNameFor(type, unit, number),
            CurrentIntervalTotal: ClampInt32(normalized.Total),
            // 注意：契约字段 currentIntervalUsed 实际存放剩余量（Swift 注释“API: 这是剩余数量，不是已用！”）。
            CurrentIntervalRemaining: ClampInt32(normalized.Remaining),
            WeeklyTotal: 0,
            WeeklyRemaining: 0,
            RemainsTimeMilliseconds: endTime is null ? 0 : RemainingMilliseconds(endTime.Value, at),
            StartTime: startTime,
            EndTime: endTime,
            WeeklyStartTime: null,
            WeeklyEndTime: null,
            ValueSuffix: normalized.ValueSuffix,
            DetailText: DetailTextFor(percentage, usageDetails, normalized.Used, normalized.Total),
            CurrentIntervalRemainingPercent: null,
            WeeklyRemainingPercent: null,
            ProgressBarPercentOverride: null,
            ProgressBarRightText: null,
            SampledAt: null);
    }

    private readonly record struct NormalizedQuota(long Used, long Remaining, long Total, string? ValueSuffix);

    /// <summary>
    /// Swift: normalizedGLMQuotaValues(for:)。计数模式要求 usage 有效（有限、&gt;0、舍入后不溢出 Int64）且
    /// currentValue 有限；服务端 remaining 优先于 usage-currentValue 差值；剩余量钳制到 [0, usage]。
    /// 百分比兜底模式：used = clamp(percentage, 0, 100)，total = 100，ValueSuffix = "%"。
    /// </summary>
    private static NormalizedQuota NormalizeQuotaValues(double usage, double currentValue, double? remaining, double? percentage)
    {
        if (double.IsFinite(usage) && usage > 0
            && Math.Round(usage, MidpointRounding.AwayFromZero) < Int64LimitAsDouble
            && double.IsFinite(currentValue))
        {
            var total = RoundToInt64(usage);
            var used = RoundToInt64(Math.Min(Math.Max(0d, currentValue), usage));
            var rawRemaining = remaining is { } value && double.IsFinite(value)
                ? value
                : Math.Max(0d, usage - currentValue);
            var remainingCount = RoundToInt64(Math.Min(Math.Max(0d, rawRemaining), usage));
            return new NormalizedQuota(used, remainingCount, total, null);
        }

        if (percentage is { } percent && double.IsFinite(percent))
        {
            var usedPercent = RoundToInt64(Math.Min(Math.Max(percent, 0d), 100d));
            return new NormalizedQuota(usedPercent, Math.Max(0, 100 - usedPercent), 100, "%");
        }

        return new NormalizedQuota(0, 0, 0, null);
    }

    private static string ModelNameFor(string type, long? unit, long? number) => type switch
    {
        CreditLimitType => $"GLM Credits ({PeriodText(unit, number, "unknown")})",
        TokensLimitType => $"GLM Tokens ({PeriodText(unit, number, "5h")})",
        TimeLimitType => $"GLM MCP/Search ({PeriodText(unit, number, "month")})",
        _ => $"GLM {type}",
    };

    /// <summary>Swift: glmPeriodText(unit:number:fallback:) — 1=天、3=小时、5=分钟、6=周（1 周显示 weekly）。</summary>
    private static string PeriodText(long? unit, long? number, string fallback)
    {
        if (unit is null || number is null || number <= 0)
        {
            return fallback;
        }
        return unit switch
        {
            1 => $"{number}d",
            3 => $"{number}h",
            5 => $"{number}m",
            6 => number == 1 ? "weekly" : $"{number}w",
            _ => fallback,
        };
    }

    /// <summary>Swift: glmWindowDuration(for:) — 缺周期字段时仅 TOKENS_LIMIT 回退 5 小时。</summary>
    private static TimeSpan? WindowDuration(string type, long? unit, long? number)
    {
        if (unit is null || number is null || number <= 0)
        {
            return type == TokensLimitType ? TimeSpan.FromHours(5) : null;
        }
        var multiplierSeconds = unit switch
        {
            1 => (long?)24 * 3600,
            3 => (long?)3600,
            5 => (long?)60,
            6 => (long?)7 * 24 * 3600,
            _ => null,
        };
        if (multiplierSeconds is null)
        {
            return null;
        }
        return TimeSpan.FromSeconds(number.Value * multiplierSeconds.Value);
    }

    /// <summary>
    /// Swift: glmDetailText(for:used:total:) — “X.X% used”（或 “N used”）+ 用量前 3 的模型明细分段（" · " 连接）。
    /// </summary>
    private static string? DetailTextFor(double? percentage, List<UsageDetail> usageDetails, long used, long total)
    {
        var details = new List<string>();
        if (percentage is { } percent)
        {
            details.Add(FormattableString.Invariant($"{percent:0.0}% used"));
        }
        else if (total > 0)
        {
            details.Add($"{used} used");
        }

        var topUsages = usageDetails
            .Where(detail => detail.Usage > 0)
            .OrderByDescending(detail => detail.Usage)
            .Take(3)
            .Select(detail => $"{detail.ModelCode}: {RoundToInt64(detail.Usage)}")
            .ToList();
        if (topUsages.Count > 0)
        {
            details.Add(string.Join(" · ", topUsages));
        }

        return details.Count == 0 ? null : string.Join(" · ", details);
    }

    private readonly record struct UsageDetail(string ModelCode, double Usage);

    /// <summary>Swift: (try? decode([GLMUsageDetailItem])) ?? [] — 数组解码失败整体回退空表。</summary>
    private static List<UsageDetail> FlexibleUsageDetails(JsonElement item)
    {
        if (!TryProperty(item, "usageDetails", out var array) || array.ValueKind != JsonValueKind.Array)
        {
            return new List<UsageDetail>();
        }
        var elements = array.EnumerateArray().ToList();
        if (elements.Any(element => element.ValueKind != JsonValueKind.Object))
        {
            return new List<UsageDetail>();
        }
        return elements
            .Select(element => new UsageDetail(
                FlexibleString(element, "modelCode"),
                FlexibleDouble(element, "usage")))
            .ToList();
    }

    private static int RemainingMilliseconds(DateTimeOffset endTime, DateTimeOffset at)
    {
        var milliseconds = (endTime - at).TotalMilliseconds;
        var truncated = (long)milliseconds; // Swift Int(...)：向零截断
        return truncated > 0 ? ClampInt32(truncated) : 0;
    }

    /// <summary>契约字段为 int（Swift Int 64 位）；现实负载远小于 int 上限，这里防御性钳制。</summary>
    private static int ClampInt32(long value) => value < 0 ? 0 : value > int.MaxValue ? int.MaxValue : (int)value;

    /// <summary>Swift .rounded() = .toNearestOrAwayFromZero；必须用 AwayFromZero，默认银行家舍入会算错 12.5 → 13。</summary>
    private static long RoundToInt64(double value) => (long)Math.Round(value, MidpointRounding.AwayFromZero);

    // ------------------------------------------------------------------
    // decodeFlexible* 容错解码（AIQuotaBar/Models/UsageData.swift:786-848 的逐条对应）。
    // 语义：数字/数字字符串双形态；必填变体兜底 0/""，可选变体仅“键缺失”时为 null。
    // ------------------------------------------------------------------

    private static bool TryProperty(JsonElement element, string name, out JsonElement value)
    {
        value = default;
        return element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out value);
    }

    private static string FlexibleString(JsonElement element, string name)
    {
        if (!TryProperty(element, name, out var value))
        {
            return string.Empty;
        }
        return value.ValueKind switch
        {
            JsonValueKind.String => value.GetString() ?? string.Empty,
            // Swift: Int → String(int) / Double → String(double)，与原始数字文本一致。
            JsonValueKind.Number => value.GetRawText(),
            _ => string.Empty,
        };
    }

    private static double FlexibleDouble(JsonElement element, string name)
    {
        if (!TryProperty(element, name, out var value))
        {
            return 0d;
        }
        if (value.ValueKind == JsonValueKind.Number)
        {
            return value.TryGetDouble(out var parsed) ? parsed : 0d;
        }
        if (value.ValueKind == JsonValueKind.String)
        {
            var text = value.GetString() ?? string.Empty;
            return double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed)
                ? parsed
                : 0d;
        }
        return 0d;
    }

    private static double? FlexibleOptionalDouble(JsonElement element, string name)
    {
        // Swift: guard contains(key) else nil —— 显式 null / 垃圾字符串会落到 0.0 而不是 null。
        if (!TryProperty(element, name, out _))
        {
            return null;
        }
        return FlexibleDouble(element, name);
    }

    private static long? FlexibleOptionalInt64(JsonElement element, string name)
    {
        if (!TryProperty(element, name, out var value))
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
                return (long)doubleParsed; // Swift Int64(Double)：截断
            }
            return null;
        }
        if (value.ValueKind == JsonValueKind.String
            && long.TryParse(value.GetString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsedString))
        {
            return parsedString;
        }
        return null;
    }

    // ------------------------------------------------------------------
    // 严格信封字段（Swift 非可选 Int / Bool / String 解码：缺键或类型不符即整体解码失败）。
    // ------------------------------------------------------------------

    private static int RequiredInt32(JsonElement element, string name)
    {
        if (TryProperty(element, name, out var value)
            && value.ValueKind == JsonValueKind.Number
            && value.TryGetInt32(out var parsed))
        {
            return parsed;
        }
        throw new JsonException($"GLM 信封字段 '{name}' 缺失或不是整数。");
    }

    private static bool RequiredBoolean(JsonElement element, string name)
    {
        if (TryProperty(element, name, out var value)
            && (value.ValueKind == JsonValueKind.True || value.ValueKind == JsonValueKind.False))
        {
            return value.GetBoolean();
        }
        throw new JsonException($"GLM 信封字段 '{name}' 缺失或不是布尔值。");
    }

    private static string? OptionalString(JsonElement element, string name) =>
        TryProperty(element, name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;
}
