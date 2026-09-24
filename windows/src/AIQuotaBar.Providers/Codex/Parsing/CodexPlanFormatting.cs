// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/Providers/Codex/CodexPlanFormatting.swift
//   （displayName：exact 映射 + 分词大写化。cleanPlanName 的 ANSI/样板词清洗裁剪——
//    Codex plan_type 线上值不含 ANSI 噪声，见 usage-response-*.json fixtures）

#nullable enable

using System;
using System.Collections.Generic;
using System.Linq;

namespace AIQuotaBar.Providers.Codex.Parsing;

/// <summary>
/// Codex 计划名美化（Swift: CodexPlanFormatting.displayName）：pro → "Pro 20x"、
/// prolite 系 → "Pro 5x"，其余按 _/-/空白分词后逐词首字母大写（全大写词与 cbp/k12 保留大写）。
/// </summary>
public static class CodexPlanFormatting
{
    private static readonly IReadOnlyDictionary<string, string> ExactDisplayNames =
        new Dictionary<string, string>
        {
            ["pro"] = "Pro 20x",
            ["prolite"] = "Pro 5x",
            ["pro_lite"] = "Pro 5x",
            ["pro-lite"] = "Pro 5x",
            ["pro lite"] = "Pro 5x",
        };

    private static readonly IReadOnlySet<string> UppercaseWords = new HashSet<string>
    {
        "cbp",
        "k12",
    };

    public static string? DisplayName(string? raw)
    {
        if (raw is null)
        {
            return null;
        }

        var candidate = raw.Trim();
        if (candidate.Length == 0)
        {
            return null;
        }

        if (ExactDisplayNames.TryGetValue(candidate.ToLowerInvariant(), out var exact))
        {
            return exact;
        }

        var components = candidate
            .Split('_', '-', ' ', '\t')
            .Where(part => part.Length != 0)
            .ToList();
        if (components.Count == 0)
        {
            return candidate;
        }

        var formatted = string.Join(" ", components.Select(WordDisplayName));
        return formatted.Length == 0 ? candidate : formatted;
    }

    private static string WordDisplayName(string raw)
    {
        var lower = raw.ToLowerInvariant();
        if (UppercaseWords.Contains(lower))
        {
            return lower.ToUpperInvariant();
        }

        if (raw == raw.ToUpperInvariant() && raw.Any(char.IsLetter))
        {
            return raw;
        }

        if (char.IsLower(raw[0]))
        {
            return char.ToUpperInvariant(raw[0]) + raw[1..];
        }

        return raw;
    }
}
