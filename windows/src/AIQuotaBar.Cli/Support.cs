// Swift 来源：无（Windows 端新增；CLI 公共支撑：HttpClient 构建与 UsageData 展示）。

#nullable enable

using System.Net;
using System.Text.Json;
using AIQuotaBar.Core.Contracts;
using AIQuotaBar.Core.Quota;

namespace AIQuotaBar.Cli;

internal static class Support
{
    public static HttpClient CreateHttpClient(CliOptions options)
    {
        HttpClientHandler handler = new()
        {
            AutomaticDecompression = DecompressionMethods.All,
        };
        if (options.Proxy is not null)
        {
            handler.Proxy = new WebProxy(options.Proxy);
            handler.UseProxy = true;
        }

        return new HttpClient(handler, disposeHandler: true) { Timeout = options.Timeout };
    }

    /// <summary>人类可读的配额摘要；options.Json 时输出线上契约 JSON。</summary>
    public static void PrintUsage(UsageData data, CliOptions options)
    {
        if (options.Json)
        {
            Console.WriteLine(JsonSerializer.Serialize(data, QuotaJson.Default));
            return;
        }

        var pct = data.PercentageRemaining();
        Console.WriteLine($"provider     : {data.Provider.DisplayName()}");
        Console.WriteLine($"remains      : {data.Remains} / {data.Total} ({pct:F1}%)");
        Console.WriteLine($"timestamp    : {QuotaJson.FormatStrictSwiftIso8601(data.Timestamp)}");
        if (data.SubscribeTitle is not null)
        {
            Console.WriteLine($"subscribe    : {data.SubscribeTitle}"
                + (data.SubscribeEndTime is { } end ? $"（至 {QuotaJson.FormatStrictSwiftIso8601(end)}）" : null));
        }

        Console.WriteLine($"models       : {data.Models.Count}");
        foreach (var m in data.Models)
        {
            var account = string.IsNullOrEmpty(m.AccountName) ? "-" : m.AccountName;
            var suffix = m.ValueSuffix ?? string.Empty;
            var reset = m.EndTime is { } e ? $" resets={QuotaJson.FormatStrictSwiftIso8601(e)}" : null;
            var detail = string.IsNullOrEmpty(m.DetailText) ? null : $" detail={m.DetailText}";
            Console.WriteLine($"  [{account}] {m.ModelName}: {m.CurrentIntervalRemaining}/{m.CurrentIntervalTotal}{suffix}"
                + (m.CurrentIntervalRemainingPercent is { } p ? $" ({p}%)" : null) + reset + detail);
        }
    }

    /// <summary>凭据掩码：保留首尾各 2 字符与长度，避免日志/控制台泄漏完整密钥。</summary>
    public static string Mask(string secret)
    {
        return secret.Length <= 6
            ? new string('*', secret.Length)
            : $"{secret[..2]}...{secret[^2..]} (len={secret.Length})";
    }
}
