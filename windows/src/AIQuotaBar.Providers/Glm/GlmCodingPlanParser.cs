// Swift 来源：无（Windows 端新增）——ZCode 桌面客户端（Electron）的 coding-plan 余额端点
// GET https://zcode.z.ai/api/v1/zcode-plan/billing/balance?app_version=3.14.3（Bearer JWT，
// 凭据存 ~/.zcode/v2/credentials.json）。macOS Swift 端无对应实现。
// 契约即源：响应形状由真实抓包样本 windows/contracts/fixtures/glm/coding-plan-balance.real.json
// 钉死（[real-captured]，ZCode 3.14.3 Windows 客户端日志录制于 2026-09-27，账号唯一 ID/logid 已脱敏，
// 见 contracts/fixtures/MANIFEST.md）；此前按假设形状合成的样本已按 fixtures 政策 1 删除。
// 相对旧合成契约的校准结论（全部由 real fixture 实证）：
// - 信封成功码是 code=0（非 bigmodel.cn 端点的 200），错误详情在 msg，无 success 布尔；
// - 负载是 data.balances[] 余额桶数组（非 data.total/remaining 扁平计数）：每桶一行，模型行名取
//   show_name；total_units/remaining_units 为 JSON number 计数（token 制）；
// - data.plans[]（status="active"）承载订阅元数据：priority 最高者的 name → SubscribeTitle
//   （并列时按出现顺序拼接去重），active plan 的 ends_at 最大值 → SubscribeEndTime；
// - 时间字段（period_start/period_end/starts_at/ends_at/server_time）一律 Unix 秒——不是毫秒
//   （GlmQuotaParser 的 nextResetTime 是毫秒，勿混），也不是 ISO8601 文本；仓库有过 epoch ticks
//   vs Unix 秒的前车之鉴（docs/windows-port-plan-2026-09-24.md §0），此处由 real fixture 实证为秒。
// data.server_time 刻意不用：Timestamp 一律取取样时刻 now（与 GlmQuotaParser 一致）。
// 对应测试：tests/AIQuotaBar.Providers.Tests/Glm/GlmCodingPlanTests.cs（real fixture 驱动 + 坏形状派生变换）。

using System.Globalization;
using System.Text.Json;
using AIQuotaBar.Core.Contracts;

namespace AIQuotaBar.Providers.Glm;

/// <summary>
/// ZCode coding-plan 余额响应解析。纯函数、无 I/O；balances[] 每个余额桶一行，计数负载
/// （remaining/total）归一为百分比制（对齐 Kimi/Codex 行的百分比语义：CurrentIntervalTotal=100、
/// ValueSuffix="%"），原始计数保留在 DetailText（"241495318 / 300000000 tokens"）以免百分比换算
/// 丢失信息；plans[] 的 active 计划映射 SubscribeTitle / SubscribeEndTime。
/// </summary>
public static class GlmCodingPlanParser
{
    /// <summary>plans[].status 的有效订阅状态值（real fixture 钉死；过期/停用计划不参与订阅映射）。</summary>
    private const string ActivePlanStatus = "active";

    /// <summary>SubscribeTitle 并列（同最高 priority）时的拼接分隔符（对齐 DetailText 的 " · " 分段惯例）。</summary>
    private const string TitleSeparator = " · ";

    /// <param name="now">取样时刻，决定 Timestamp 与 RemainsTimeMilliseconds；测试注入。</param>
    /// <exception cref="GlmUsageException">
    /// InvalidResponse：非 JSON / 信封与字段形状不符（错误信息含字段名）；ApiError：code != 0（msg 进错误信息）。
    /// </exception>
    public static UsageData Parse(string json, DateTimeOffset? now = null)
    {
        var at = now ?? DateTimeOffset.UtcNow;
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;

            var code = RequiredEnvelopeCode(root);
            if (code != 0)
            {
                var message = OptionalString(root, "msg");
                throw new GlmUsageException(
                    GlmUsageErrorKind.ApiError,
                    string.IsNullOrWhiteSpace(message)
                        ? FormattableString.Invariant($"GLM coding-plan 接口返回错误码 code={code}。")
                        : message!);
            }

            var data = RequiredDataObject(root);
            var balances = RequiredArray(data, "balances");

            var rows = new List<ModelUsageData>();
            foreach (var balance in balances.EnumerateArray())
            {
                rows.Add(RowFrom(balance, at));
            }
            if (rows.Count == 0)
            {
                // 空 balances 与空 limits 同罪：错误而非“连接成功但没有数据”（GlmQuotaParser 先例）。
                throw new GlmUsageException(
                    GlmUsageErrorKind.InvalidResponse,
                    "GLM coding-plan 余额响应字段 'balances' 为空数组（无任何余额桶）。");
            }

            var subscription = SubscriptionFrom(data);

            // Remains 语义 = 当前周期仍有额度的模型行数（GlmQuotaParser.IsCurrentIntervalAvailable
            // 同义：百分比模式看 >0）。Total = 余额桶行数。
            var remains = rows.Count(row => row.CurrentIntervalRemaining > 0);
            return new UsageData(
                UsageProvider.Glm,
                remains,
                rows.Count,
                at,
                rows,
                SubscribeTitle: subscription.Title,
                SubscribeEndTime: subscription.EndTime,
                GlmResetAllowances: null);
        }
        catch (JsonException ex)
        {
            throw new GlmUsageException(
                GlmUsageErrorKind.InvalidResponse, "GLM coding-plan 余额响应不是合法 JSON。", ex);
        }
    }

    // ------------------------------------------------------------------
    // balances[] → 模型行
    // ------------------------------------------------------------------

    /// <summary>单个余额桶 → 一行模型额度（百分比制，原始计数入 DetailText）。</summary>
    private static ModelUsageData RowFrom(JsonElement balance, DateTimeOffset at)
    {
        if (balance.ValueKind != JsonValueKind.Object)
        {
            throw new GlmUsageException(
                GlmUsageErrorKind.InvalidResponse, "GLM coding-plan 余额响应字段 'balances' 含非对象元素。");
        }

        var modelName = RequiredString(balance, "show_name");
        var total = RequiredFiniteNumber(balance, "total_units");
        if (total <= 0)
        {
            throw new GlmUsageException(
                GlmUsageErrorKind.InvalidResponse,
                $"GLM coding-plan 余额响应字段 'total_units' 必须为正数（实然 {total.ToString("R", CultureInfo.InvariantCulture)}）。");
        }

        // remaining 越界不抛错，钳制到 [0, total] 后再换算百分比（对齐 GlmQuotaParser 的钳制哲学）。
        var remaining = RequiredFiniteNumber(balance, "remaining_units");
        var remainingClamped = Math.Min(Math.Max(remaining, 0d), total);

        // 周期窗口可缺失：缺失不伪造（对齐 GlmQuotaParser 对 5h 无 reset 元数据的处理）；
        // 存在但不是 Unix 秒整数 → 拒绝（错误信息含字段名）。expires_at 与 period_end 恒同值，不重复读。
        var startTime = OptionalUnixSeconds(balance, "period_start");
        var endTime = OptionalUnixSeconds(balance, "period_end");

        var remainingPercent = RoundToInt64(remainingClamped / total * 100d); // 比率 ∈ [0,1] → 结果 ∈ [0,100]
        return new ModelUsageData(
            UsageProvider.Glm,
            AccountName: null,
            ModelName: modelName,
            CurrentIntervalTotal: 100,
            // 契约字段 currentIntervalUsed 实际存放剩余量（Core/Contracts/UsageData.cs 头注）。
            CurrentIntervalRemaining: (int)remainingPercent,
            WeeklyTotal: 0,
            WeeklyRemaining: 0,
            RemainsTimeMilliseconds: endTime is { } end ? RemainingMilliseconds(end, at) : 0,
            StartTime: startTime,
            EndTime: endTime,
            WeeklyStartTime: null,
            WeeklyEndTime: null,
            ValueSuffix: "%",
            DetailText: FormattableString.Invariant(
                $"{RoundToInt64(remainingClamped)} / {RoundToInt64(total)} {UnitLabel(balance)}"),
            CurrentIntervalRemainingPercent: (int)remainingPercent,
            WeeklyRemainingPercent: null,
            ProgressBarPercentOverride: null,
            ProgressBarRightText: null,
            SampledAt: null);
    }

    /// <summary>DetailText 的单位标注：unit_type（real fixture 为 "token"）按英文复数补 "s"，缺失时默认 "tokens"。</summary>
    private static string UnitLabel(JsonElement balance) =>
        OptionalString(balance, "unit_type") is { } unitType
            ? (unitType.EndsWith("s", StringComparison.Ordinal) ? unitType : unitType + "s")
            : "tokens";

    // ------------------------------------------------------------------
    // plans[] → 订阅元数据
    // ------------------------------------------------------------------

    /// <summary>
    /// plans[]（status="active"）→ (SubscribeTitle, SubscribeEndTime)。status 是过期的唯一权威判定，
    /// 不用时钟二次推断；标题取 priority 最高者的 name（并列时按出现顺序拼接去重）；
    /// SubscribeEndTime 取全部 active 计划 ends_at 的最大值（订阅整体到期时刻）。
    /// plans 键缺失/为 null → 无订阅信息（余额行不受影响）；字段存在但类型不符 → 拒绝。
    /// </summary>
    private static (string? Title, DateTimeOffset? EndTime) SubscriptionFrom(JsonElement data)
    {
        if (data.ValueKind != JsonValueKind.Object
            || !data.TryGetProperty("plans", out var plans)
            || plans.ValueKind == JsonValueKind.Null)
        {
            return (null, null);
        }
        if (plans.ValueKind != JsonValueKind.Array)
        {
            throw new GlmUsageException(
                GlmUsageErrorKind.InvalidResponse, "GLM coding-plan 余额响应字段 'plans' 存在但不是数组。");
        }

        var activePlans = new List<(int Priority, string? Name, DateTimeOffset? EndsAt)>();
        foreach (var plan in plans.EnumerateArray())
        {
            if (plan.ValueKind != JsonValueKind.Object)
            {
                throw new GlmUsageException(
                    GlmUsageErrorKind.InvalidResponse, "GLM coding-plan 余额响应字段 'plans' 含非对象元素。");
            }
            if (!IsActive(plan))
            {
                continue;
            }
            // priority 缺失按最低优先级参与排序（不伪造高排名）；存在但非整数 → 拒绝。
            var priority = OptionalInt32(plan, "priority") ?? int.MinValue;
            activePlans.Add((priority, OptionalString(plan, "name"), OptionalUnixSeconds(plan, "ends_at")));
        }
        if (activePlans.Count == 0)
        {
            return (null, null);
        }

        var topPriority = activePlans.Max(plan => plan.Priority);
        var title = string.Join(
            TitleSeparator,
            activePlans
                .Where(plan => plan.Priority == topPriority)
                .Select(plan => plan.Name)
                .OfType<string>()
                .Distinct(StringComparer.Ordinal));
        var ends = activePlans
            .Select(plan => plan.EndsAt)
            .OfType<DateTimeOffset>()
            .ToList();

        return (
            title.Length > 0 ? title : null,
            ends.Count > 0 ? ends.Max() : null);
    }

    /// <summary>status 为字符串且等于 "active"（real fixture 钉死）；其余形态一律视为非 active（过滤，不抛错）。</summary>
    private static bool IsActive(JsonElement plan) =>
        plan.TryGetProperty("status", out var status)
        && status.ValueKind == JsonValueKind.String
        && string.Equals(status.GetString(), ActivePlanStatus, StringComparison.Ordinal);

    // ------------------------------------------------------------------
    // 严格字段解码：形状不符直接抛 GlmUsageException 且错误信息含字段名
    // （区别于 GlmQuotaParser 走 JsonException 的兜底文案——本端点契约由 real fixture 钉死）。
    // TODO(W1): 共享 UsageError 落地时与 GlmQuotaParser / GlmResetAllowanceParser 一并统一解码助手。
    // ------------------------------------------------------------------

    /// <summary>信封 code：必填整数（real fixture 钉死：成功码 0，非 bigmodel.cn 端点的 200；无 success 布尔）。</summary>
    private static int RequiredEnvelopeCode(JsonElement root)
    {
        if (root.ValueKind == JsonValueKind.Object
            && root.TryGetProperty("code", out var value)
            && value.ValueKind == JsonValueKind.Number
            && value.TryGetInt32(out var code))
        {
            return code;
        }
        throw new GlmUsageException(
            GlmUsageErrorKind.InvalidResponse, "GLM coding-plan 余额响应信封字段 'code' 缺失或不是整数。");
    }

    private static JsonElement RequiredDataObject(JsonElement root)
    {
        if (root.ValueKind == JsonValueKind.Object
            && root.TryGetProperty("data", out var data)
            && data.ValueKind == JsonValueKind.Object)
        {
            return data;
        }
        throw new GlmUsageException(
            GlmUsageErrorKind.InvalidResponse, "GLM coding-plan 余额响应缺少 'data' 负载对象。");
    }

    private static JsonElement RequiredArray(JsonElement data, string name)
    {
        if (data.ValueKind == JsonValueKind.Object
            && data.TryGetProperty(name, out var value)
            && value.ValueKind == JsonValueKind.Array)
        {
            return value;
        }
        throw new GlmUsageException(
            GlmUsageErrorKind.InvalidResponse, $"GLM coding-plan 余额响应字段 '{name}' 缺失或不是数组。");
    }

    private static string RequiredString(JsonElement element, string name)
    {
        if (element.ValueKind == JsonValueKind.Object
            && element.TryGetProperty(name, out var value)
            && value.ValueKind == JsonValueKind.String
            && value.GetString() is { } parsed)
        {
            return parsed;
        }
        throw new GlmUsageException(
            GlmUsageErrorKind.InvalidResponse, $"GLM coding-plan 余额响应字段 '{name}' 缺失或不是字符串。");
    }

    /// <summary>必填有限数字（real fixture 钉死为 JSON number；字符串数字形态未见于真实样本，不放宽）。</summary>
    private static double RequiredFiniteNumber(JsonElement data, string name)
    {
        if (data.ValueKind == JsonValueKind.Object
            && data.TryGetProperty(name, out var value)
            && value.ValueKind == JsonValueKind.Number
            && value.TryGetDouble(out var parsed)
            && double.IsFinite(parsed))
        {
            return parsed;
        }
        throw new GlmUsageException(
            GlmUsageErrorKind.InvalidResponse, $"GLM coding-plan 余额响应字段 '{name}' 缺失或不是数字。");
    }

    /// <summary>
    /// 可选 Unix 秒时间戳：键缺失或显式 null → null；存在但非整数秒 → 抛错。
    /// 单位是秒（real fixture 钉死）——与 GlmQuotaParser 的 nextResetTime（毫秒）语义不同，勿混。
    /// </summary>
    private static DateTimeOffset? OptionalUnixSeconds(JsonElement element, string name)
    {
        if (element.ValueKind != JsonValueKind.Object
            || !element.TryGetProperty(name, out var value)
            || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var seconds))
        {
            return DateTimeOffset.FromUnixTimeSeconds(seconds);
        }
        throw new GlmUsageException(
            GlmUsageErrorKind.InvalidResponse,
            $"GLM coding-plan 余额响应字段 '{name}' 存在但不是 Unix 秒时间戳（整数秒数字）。");
    }

    /// <summary>可选整数（plans[].priority 排名用）：键缺失或显式 null → null；存在但非整数 → 抛错。</summary>
    private static int? OptionalInt32(JsonElement element, string name)
    {
        if (element.ValueKind != JsonValueKind.Object
            || !element.TryGetProperty(name, out var value)
            || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var parsed))
        {
            return parsed;
        }
        throw new GlmUsageException(
            GlmUsageErrorKind.InvalidResponse, $"GLM coding-plan 余额响应字段 '{name}' 存在但不是整数。");
    }

    /// <summary>可选自由文本（msg / name / unit_type）：键缺失、null 或非字符串都按“无值”处理，不抛错。</summary>
    private static string? OptionalString(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object
        && element.TryGetProperty(name, out var value)
        && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    // ------------------------------------------------------------------
    // 与 GlmQuotaParser 同语义的私有辅助（该处为 private，无法复用；数值取舍注释见原处）。
    // ------------------------------------------------------------------

    private static int RemainingMilliseconds(DateTimeOffset endTime, DateTimeOffset at)
    {
        var milliseconds = (endTime - at).TotalMilliseconds;
        var truncated = (long)milliseconds; // Swift Int(...)：向零截断
        return truncated > 0 ? ClampInt32(truncated) : 0;
    }

    private static int ClampInt32(long value) => value < 0 ? 0 : value > int.MaxValue ? int.MaxValue : (int)value;

    /// <summary>Swift .rounded() = .toNearestOrAwayFromZero；必须 AwayFromZero，默认银行家舍入会算错 12.5 → 13。</summary>
    private static long RoundToInt64(double value) => (long)Math.Round(value, MidpointRounding.AwayFromZero);
}
