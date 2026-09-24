// Swift 来源：AIQuotaBar/Services/Clash/ClashConfigurationDiscovery.swift — enum ClashTopLevelYAML（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashConfigurationDiscoveryTests.swift — testTopLevelYAMLReadsControllerAndQuotedSecretWithoutNestedKeys
// fixtures：windows/contracts/fixtures/clash/clash-verge-config.yaml

#nullable enable

using System;
using System.Collections.Generic;
using System.Text.Json;
using AIQuotaBar.Core.Contracts;

namespace AIQuotaBar.Providers.Clash;

/// <summary>
/// 只读解析 Clash 配置文件的**顶层**标量键值（external-controller / secret 等）：
/// 跳过缩进行（嵌套键）与注释行；值支持单引号（'' 转义）、双引号（JSON 字符串）与 " #" 行内注释。
/// </summary>
public static class ClashTopLevelYaml
{
    public static IReadOnlyDictionary<string, string> Parse(string contents)
    {
        var result = new Dictionary<string, string>();

        foreach (var rawLine in contents.Replace("\r\n", "\n").Split('\n'))
        {
            if (rawLine.Length == 0)
            {
                continue;
            }

            var first = rawLine[0];
            if (char.IsWhiteSpace(first) || first == '#')
            {
                continue;
            }

            var separator = rawLine.IndexOf(':');
            if (separator < 0)
            {
                continue;
            }

            var key = rawLine[..separator].Trim();
            if (key.Length == 0)
            {
                continue;
            }

            result[key] = DecodeScalar(rawLine[(separator + 1)..]);
        }

        return result;
    }

    private static string DecodeScalar(string rawValue)
    {
        var trimmed = rawValue.Trim();
        if (trimmed.Length == 0)
        {
            return string.Empty;
        }

        if (trimmed.StartsWith('\''))
        {
            var closingIndex = ClosingSingleQuote(trimmed);
            if (closingIndex < 0)
            {
                return trimmed[1..];
            }

            return trimmed[1..closingIndex].Replace("''", "'");
        }

        if (trimmed.StartsWith('"'))
        {
            // 与 Swift 一致：先按 JSON 字符串解码（处理转义），失败再退回「到闭引号为止」的字面截取。
            try
            {
                var decoded = JsonSerializer.Deserialize<string>(trimmed, QuotaJson.Default);
                if (decoded is not null)
                {
                    return decoded;
                }
            }
            catch (JsonException)
            {
                // 落到闭引号截取。
            }

            var closingDoubleQuote = ClosingDoubleQuote(trimmed);
            if (closingDoubleQuote >= 0)
            {
                return trimmed[1..closingDoubleQuote];
            }
        }

        var commentIndex = trimmed.IndexOf(" #", StringComparison.Ordinal);
        if (commentIndex >= 0)
        {
            return trimmed[..commentIndex].Trim();
        }

        return trimmed;
    }

    private static int ClosingSingleQuote(string value)
    {
        for (var index = 1; index < value.Length; index++)
        {
            if (value[index] != '\'')
            {
                continue;
            }

            if (index + 1 < value.Length && value[index + 1] == '\'')
            {
                index++; // '' 为转义的单引号，跳过两个字符。
                continue;
            }

            return index;
        }

        return -1;
    }

    private static int ClosingDoubleQuote(string value)
    {
        var isEscaped = false;
        for (var index = 1; index < value.Length; index++)
        {
            var character = value[index];
            if (character == '"' && !isEscaped)
            {
                return index;
            }

            isEscaped = character == '\\';
        }

        return -1;
    }
}
