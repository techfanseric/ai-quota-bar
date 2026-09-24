// Swift 来源：AIQuotaBar/Services/Clash/ClashConnectionModels.swift — enum ClashConnectionDateParser（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashConnectionTests.swift — testConnectionsResponseDecodesMihomoFields

#nullable enable

using System;
using System.Globalization;

namespace AIQuotaBar.Providers.Clash;

/// <summary>解析 mihomo start 字段：微秒精度 ISO 8601（fractional）优先，其次秒精度；始终规范化为 UTC。</summary>
public static class ClashConnectionDateParser
{
    private static readonly string[] AcceptedFormats =
    {
        "yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'",
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        "yyyy-MM-dd'T'HH:mm:ss.FFFFFFFzzz",
        "yyyy-MM-dd'T'HH:mm:sszzz",
    };

    public static DateTimeOffset? Date(string value)
    {
        if (DateTimeOffset.TryParseExact(
                value,
                AcceptedFormats,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal,
                out var result))
        {
            return result.ToUniversalTime();
        }

        return null;
    }
}
