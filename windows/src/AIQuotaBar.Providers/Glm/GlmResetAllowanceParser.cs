// Swift 来源：AIQuotaBar/Models/GLMResetAllowances.swift — static func decode(_:)。
// 数据形状 GlmResetAllowances（Core 契约，只读）头注指明 decode 属于 Providers 层任务：
// 严格 "yyyy-MM-dd HH:mm:ss" Asia/Shanghai(UTC+8) expireTime，带回往返校验；只保留 available == true；
// 列表升序；非 200 / 非 PERSONAL 载荷拒绝（UsageError.invalidResponse 语义 → GlmUsageException）。
// 对应测试：AIQuotaBar/Tests/GLM/GLMResetAllowanceTests.swift:5-17（fixtures：reset-allowances-*.json）。

using System.Globalization;
using System.Text.Json;
using AIQuotaBar.Core.Contracts;

namespace AIQuotaBar.Providers.Glm;

/// <summary>
/// GLM 个人 Coding-Plan 重置权益响应解析（Swift: GLMResetAllowances.decode）。纯函数、无 I/O。
/// </summary>
public static class GlmResetAllowanceParser
{
    private static readonly TimeSpan ShanghaiOffset = TimeSpan.FromHours(8);
    private const string ExpireTimeFormat = "yyyy-MM-dd HH:mm:ss";

    /// <exception cref="GlmUsageException">InvalidResponse：信封不通过、非 PERSONAL、时间格式非法。</exception>
    public static GlmResetAllowances Parse(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;

            var code = RequiredInt32(root, "code");
            var success = RequiredBoolean(root, "success");
            if (code != 200 || !success)
            {
                throw new GlmUsageException(
                    GlmUsageErrorKind.InvalidResponse,
                    $"GLM reset allowances 信封不通过：code={code}, success={success}。");
            }
            if (!TryPropertyObject(root, "data", out var data))
            {
                throw new GlmUsageException(
                    GlmUsageErrorKind.InvalidResponse, "GLM reset allowances 响应缺少 data 负载。");
            }

            var targetType = RequiredString(data, "targetType");
            if (targetType != "PERSONAL")
            {
                // 仅个人作用域可共享这些凭据（团队/组织拒绝）。
                throw new GlmUsageException(
                    GlmUsageErrorKind.InvalidResponse, $"targetType 非 PERSONAL：{targetType}。");
            }

            var fiveHour = ParseExpirations(data, "fiveHourResets");
            var weekly = ParseExpirations(data, "weekResets");
            return new GlmResetAllowances(fiveHour, weekly);
        }
        catch (JsonException ex)
        {
            throw new GlmUsageException(
                GlmUsageErrorKind.InvalidResponse,
                "GLM reset allowances 响应不是合法 JSON 或缺少必填数组。", ex);
        }
    }

    /// <summary>Swift fetchGLMUsage 中 try? GLMResetAllowances.decode 的 null 安全变体。</summary>
    public static GlmResetAllowances? TryParse(string json)
    {
        try
        {
            return Parse(json);
        }
        catch (GlmUsageException)
        {
            return null;
        }
    }

    private static IReadOnlyList<DateTimeOffset> ParseExpirations(JsonElement data, string propertyName)
    {
        if (!TryPropertyArray(data, propertyName, out var items))
        {
            throw new JsonException($"GLM reset allowances 的 data.{propertyName} 缺失或不是数组。");
        }
        var expirations = new List<DateTimeOffset>();
        foreach (var item in items.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object
                || !item.TryGetProperty("available", out var available)
                || (available.ValueKind != JsonValueKind.True && available.ValueKind != JsonValueKind.False))
            {
                throw new JsonException("GLM reset 条目不是带布尔 available 的对象。");
            }
            if (!available.GetBoolean())
            {
                continue; // 只统计 available == true
            }
            var expireTime = RequiredString(item, "expireTime");
            expirations.Add(ParseShanghaiTime(expireTime));
        }
        // 升序排列（Swift .sorted()）；已过期条目保留，available(at:) 过滤是 Core 逻辑。
        return expirations.OrderBy(expiration => expiration).ToList();
    }

    private static DateTimeOffset ParseShanghaiTime(string raw)
    {
        // Swift：en_US_POSIX + Asia/Shanghai + isLenient(false)，随后 string(from:) == 输入 的往返校验。
        if (!DateTime.TryParseExact(
                raw, ExpireTimeFormat, CultureInfo.InvariantCulture, DateTimeStyles.None, out var wallClock))
        {
            throw new GlmUsageException(
                GlmUsageErrorKind.InvalidResponse,
                $"expireTime 不是严格的秒级时间文本（{ExpireTimeFormat}）：{raw}");
        }
        var value = new DateTimeOffset(wallClock, ShanghaiOffset);
        if (value.ToString(ExpireTimeFormat, CultureInfo.InvariantCulture) != raw)
        {
            throw new GlmUsageException(
                GlmUsageErrorKind.InvalidResponse, $"expireTime 往返校验失败：{raw}");
        }
        return value;
    }

    // ------------------------------------------------------------------
    // 严格信封字段辅助（与 GlmQuotaParser 同语义；TODO(W1): 共享 UsageError 落地时一并提供共享解码助手）。
    // ------------------------------------------------------------------

    private static bool TryPropertyObject(JsonElement element, string name, out JsonElement value)
    {
        value = default;
        return element.ValueKind == JsonValueKind.Object
            && element.TryGetProperty(name, out value)
            && value.ValueKind == JsonValueKind.Object;
    }

    private static bool TryPropertyArray(JsonElement element, string name, out JsonElement value)
    {
        value = default;
        return element.ValueKind == JsonValueKind.Object
            && element.TryGetProperty(name, out value)
            && value.ValueKind == JsonValueKind.Array;
    }

    private static int RequiredInt32(JsonElement element, string name)
    {
        if (element.ValueKind == JsonValueKind.Object
            && element.TryGetProperty(name, out var value)
            && value.ValueKind == JsonValueKind.Number
            && value.TryGetInt32(out var parsed))
        {
            return parsed;
        }
        throw new JsonException($"GLM 信封字段 '{name}' 缺失或不是整数。");
    }

    private static bool RequiredBoolean(JsonElement element, string name)
    {
        if (element.ValueKind == JsonValueKind.Object
            && element.TryGetProperty(name, out var value)
            && (value.ValueKind == JsonValueKind.True || value.ValueKind == JsonValueKind.False))
        {
            return value.GetBoolean();
        }
        throw new JsonException($"GLM 信封字段 '{name}' 缺失或不是布尔值。");
    }

    private static string RequiredString(JsonElement element, string name)
    {
        if (element.ValueKind == JsonValueKind.Object
            && element.TryGetProperty(name, out var value)
            && value.ValueKind == JsonValueKind.String)
        {
            return value.GetString() ?? string.Empty;
        }
        throw new JsonException($"GLM 字段 '{name}' 缺失或不是字符串。");
    }
}
