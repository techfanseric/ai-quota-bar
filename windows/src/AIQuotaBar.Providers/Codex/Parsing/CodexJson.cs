// Swift 来源：无（Windows 端新增）。集中容忍式 JSON 取值辅助：镜像 Swift 各 Decodable
// init 里的 try? decodeIfPresent / 灵活数字（CodexSpendControlNumber）语义。

#nullable enable

using System;
using System.Globalization;
using System.Text.Json;

namespace AIQuotaBar.Providers.Codex.Parsing;

/// <summary>
/// 容忍式 JSON 读取辅助（internal）：字段缺失/类型不符一律返回 null，绝不抛出——
/// 与 Swift 侧 `try? container.decodeIfPresent(...)` 的损失容忍解码对齐。
/// </summary>
internal static class CodexJson
{
    /// <summary>首个命中且为字符串的键（键名精确匹配，按序回退）。</summary>
    public static string? String(JsonElement element, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (element.ValueKind == JsonValueKind.Object &&
                element.TryGetProperty(key, out var value) &&
                value.ValueKind == JsonValueKind.String)
            {
                return value.GetString();
            }
        }

        return null;
    }

    /// <summary>首个命中且为 JSON 整数的键（非整数数字如 3.5 不接受——Swift decode(Int) 同语义）。</summary>
    public static int? Int32(JsonElement element, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (element.ValueKind == JsonValueKind.Object &&
                element.TryGetProperty(key, out var value) &&
                value.ValueKind == JsonValueKind.Number &&
                value.TryGetInt32(out var parsed))
            {
                return parsed;
            }
        }

        return null;
    }

    /// <summary>
    /// 灵活 double（Swift: CodexSpendControlNumber.double）：数字，或可解析为有限 double 的
    /// 字符串（trim 后）；"NaN"/"Infinity" 及溢出字符串拒绝（Swift Double(String) 同语义）。
    /// </summary>
    public static double? FlexibleDouble(JsonElement element, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (element.ValueKind != JsonValueKind.Object ||
                !element.TryGetProperty(key, out var value) ||
                value.ValueKind == JsonValueKind.Null)
            {
                continue;
            }

            if (value.ValueKind == JsonValueKind.Number)
            {
                var parsed = value.GetDouble();
                return double.IsFinite(parsed) ? parsed : null;
            }

            if (value.ValueKind == JsonValueKind.String)
            {
                var text = value.GetString()?.Trim();
                if (text is not null &&
                    double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsedText) &&
                    double.IsFinite(parsedText))
                {
                    return parsedText;
                }

                return null;
            }

            return null;
        }

        return null;
    }

    /// <summary>
    /// 灵活 int（Swift: CodexSpendControlNumber.integer）：整数数字；浮点数字仅当无小数部分
    /// （Swift Int(exactly:)）；字符串 trim 后 int.TryParse。
    /// </summary>
    public static int? FlexibleInt32(JsonElement element, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (element.ValueKind != JsonValueKind.Object ||
                !element.TryGetProperty(key, out var value) ||
                value.ValueKind == JsonValueKind.Null)
            {
                continue;
            }

            if (value.ValueKind == JsonValueKind.Number)
            {
                if (value.TryGetInt32(out var parsed))
                {
                    return parsed;
                }

                var truncated = value.GetDouble();
                if (double.IsFinite(truncated) &&
                    truncated >= int.MinValue && truncated <= int.MaxValue &&
                    Math.Truncate(truncated) == truncated)
                {
                    return (int)truncated;
                }

                return null;
            }

            if (value.ValueKind == JsonValueKind.String)
            {
                var text = value.GetString()?.Trim();
                if (text is not null &&
                    int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsedText))
                {
                    return parsedText;
                }

                return null;
            }

            return null;
        }

        return null;
    }

    /// <summary>bool 字段，类型不符/缺失时 false（Swift: (try? decode(Bool)) ?? false）。</summary>
    public static bool BoolOrFalse(JsonElement element, string key)
    {
        return element.ValueKind == JsonValueKind.Object &&
            element.TryGetProperty(key, out var value) &&
            value.ValueKind == JsonValueKind.True;
    }

    /// <summary>字段存在且非 null（Swift: hasNonNilValue——用于“解码失败”标志判定）。</summary>
    public static bool HasNonNull(JsonElement element, string key)
    {
        return element.ValueKind == JsonValueKind.Object &&
            element.TryGetProperty(key, out var value) &&
            value.ValueKind != JsonValueKind.Null;
    }

    /// <summary>ISO 8601 日期（无时区按 UTC；含小数秒可解析）。</summary>
    public static DateTimeOffset? Iso8601(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return null;
        }

        if (DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsed))
        {
            return parsed.ToUniversalTime();
        }

        return null;
    }
}
