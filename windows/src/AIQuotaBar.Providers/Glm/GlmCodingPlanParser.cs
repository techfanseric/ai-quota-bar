// Swift 来源：无（Windows 端新增）——ZCode 桌面客户端（Electron）的 coding-plan 余额端点
// https://zcode.z.ai/api/v1/zcode-plan/billing/balance（Bearer JWT，凭据存 ~/.zcode/v2/credentials.json）
// 在 macOS Swift 端无对应实现，线上响应形状亦未录制。按契约优先惯例，形状由合成 fixture
// windows/contracts/fixtures/glm/coding-plan-balance.synthetic.json 钉死（[synthesized-pending-capture]，
// 见 contracts/fixtures/MANIFEST.md），待 Windows 实机登录 ZCode 抓包后逐字段校准：
// 信封字段、数字/字符串双形态、时间戳精度与时区（Z 或 +08:00）均为校准点。
// 对应测试：tests/AIQuotaBar.Providers.Tests/Glm/GlmCodingPlanTests.cs（fixture 驱动 + 坏形状派生变换）。

using System.Globalization;
using System.Text.Json;
using AIQuotaBar.Core.Contracts;

namespace AIQuotaBar.Providers.Glm;

/// <summary>
/// ZCode coding-plan 余额响应解析。纯函数、无 I/O；计数负载（total/remaining）归一为百分比制
/// 单行 "Coding Plan"（对齐 Kimi 行的百分比语义：CurrentIntervalTotal=100、ValueSuffix="%"），
/// 原始计数保留在 DetailText（"37 / 120 left"）以免百分比换算丢失信息。
/// </summary>
public static class GlmCodingPlanParser
{
    /// <summary>coding-plan 仅有的一行额度行名（UI 展示名，任务钉死）。</summary>
    public const string ModelRowName = "Coding Plan";

    /// <param name="now">取样时刻，决定 Timestamp 与 RemainsTimeMilliseconds；测试注入。</param>
    /// <exception cref="GlmUsageException">
    /// InvalidResponse：非 JSON / 信封与字段形状不符（错误信息含字段名）；ApiError：code != 200。
    /// </exception>
    public static UsageData Parse(string json, DateTimeOffset? now = null)
    {
        var at = now ?? DateTimeOffset.UtcNow;
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;

            var code = RequiredEnvelopeCode(root);
            if (code != 200)
            {
                throw new GlmUsageException(
                    GlmUsageErrorKind.ApiError,
                    OptionalString(root, "msg") ?? "Unknown error");
            }

            var data = RequiredDataObject(root);
            var total = RequiredFiniteNumber(data, "total");
            if (total <= 0)
            {
                throw new GlmUsageException(
                    GlmUsageErrorKind.InvalidResponse,
                    $"GLM coding-plan 余额响应字段 'total' 必须为正数（实然 {total.ToString("R", CultureInfo.InvariantCulture)}）。");
            }

            // remaining 越界不抛错，钳制到 [0, total] 后再换算百分比（对齐 GlmQuotaParser 的钳制哲学）。
            var remaining = RequiredFiniteNumber(data, "remaining");
            var remainingClamped = Math.Min(Math.Max(remaining, 0d), total);

            // resetTime 缺失/畸形即拒绝：重置时刻是 coding-plan 余额的核心语义（周期归属键 = EndTime）。
            var endTime = RequiredIso8601(data, "resetTime");
            // startTime 可缺失（缺失不伪造窗口起点，对齐 GlmQuotaParser 对 5h 无 reset 元数据的处理）。
            var startTime = OptionalIso8601(data, "startTime");

            var remainingPercent = RoundToInt64(remainingClamped / total * 100d); // 比率 ∈ [0,1] → 结果 ∈ [0,100]
            var row = new ModelUsageData(
                UsageProvider.Glm,
                AccountName: null,
                ModelName: ModelRowName,
                CurrentIntervalTotal: 100,
                // 契约字段 currentIntervalUsed 实际存放剩余量（Core/Contracts/UsageData.cs 头注）。
                CurrentIntervalRemaining: (int)remainingPercent,
                WeeklyTotal: 0,
                WeeklyRemaining: 0,
                RemainsTimeMilliseconds: RemainingMilliseconds(endTime, at),
                StartTime: startTime,
                EndTime: endTime,
                WeeklyStartTime: null,
                WeeklyEndTime: null,
                ValueSuffix: "%",
                DetailText: FormattableString.Invariant(
                    $"{RoundToInt64(remainingClamped)} / {RoundToInt64(total)} left"),
                CurrentIntervalRemainingPercent: (int)remainingPercent,
                WeeklyRemainingPercent: null,
                ProgressBarPercentOverride: null,
                ProgressBarRightText: null,
                SampledAt: null);

            // Remains 语义 = 当前周期仍有额度的模型行数（GlmQuotaParser.IsCurrentIntervalAvailable 同义：百分比模式看 >0）。
            return new UsageData(
                UsageProvider.Glm,
                remainingPercent > 0 ? 1 : 0,
                1,
                at,
                new[] { row },
                SubscribeTitle: null,
                SubscribeEndTime: null,
                GlmResetAllowances: null);
        }
        catch (JsonException ex)
        {
            throw new GlmUsageException(
                GlmUsageErrorKind.InvalidResponse, "GLM coding-plan 余额响应不是合法 JSON。", ex);
        }
    }

    // ------------------------------------------------------------------
    // 严格字段解码：形状不符直接抛 GlmUsageException 且错误信息含字段名
    // （区别于 GlmQuotaParser 走 JsonException 的兜底文案——本端点无 Swift 判例，契约由测试钉）。
    // TODO(W1): 共享 UsageError 落地时与 GlmQuotaParser / GlmResetAllowanceParser 一并统一解码助手。
    // ------------------------------------------------------------------

    /// <summary>信封 code：必填整数（注意：与大 model.cn 端点不同，本端点无 success 布尔，属待校准假设）。</summary>
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

    /// <summary>必填有限数字。契约钉为 JSON number；若真实抓包发现字符串数字（大 model.cn 旧端点先例）需放宽此处。</summary>
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

    private static DateTimeOffset RequiredIso8601(JsonElement data, string name) =>
        OptionalIso8601(data, name)
        ?? throw new GlmUsageException(
            GlmUsageErrorKind.InvalidResponse,
            $"GLM coding-plan 余额响应字段 '{name}' 缺失或不是 ISO8601 时间文本。");

    /// <summary>
    /// 可选 ISO8601 时间：键缺失或显式 null → null；存在但非字符串 / 无法解析 → 抛错。
    /// 解析语义对齐 Core 的 SwiftIso8601DateTimeOffsetConverter.Read（AssumeUniversal，无偏移文本按 UTC，
    /// 机器无关；接受 Z 与任意偏移并归一到 UTC）。
    /// </summary>
    private static DateTimeOffset? OptionalIso8601(JsonElement data, string name)
    {
        if (data.ValueKind != JsonValueKind.Object
            || !data.TryGetProperty(name, out var value)
            || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        if (value.ValueKind == JsonValueKind.String
            && DateTimeOffset.TryParse(
                value.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsed))
        {
            return parsed.ToUniversalTime();
        }
        throw new GlmUsageException(
            GlmUsageErrorKind.InvalidResponse,
            $"GLM coding-plan 余额响应字段 '{name}' 缺失或不是 ISO8601 时间文本。");
    }

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
