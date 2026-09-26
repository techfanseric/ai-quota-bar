// Swift 来源：无（Windows 端新增；CLI 内置自检——确定性核心不变量的冒烟验证）。
// 范围界定：这里只做无需网络、无需真实凭据的冒烟；完整行为验收在 xUnit 套件
// （对照 Swift 测试清单），CLI selftest 是远程机器上“环境是否正常”的第一道闸。

#nullable enable

using System.Text.Json;
using AIQuotaBar.Core.Contracts;
using AIQuotaBar.Core.Quota;
using AIQuotaBar.Platform.Crypto;

namespace AIQuotaBar.Cli;

internal static class SelfTestCommand
{
    public static int Run(CliOptions options)
    {
        var t0 = CliLog.OpBegin("selftest");
        var failures = 0;

        failures += Check("契约 JSON：UsageData 往返一致", UsageJsonRoundtrip);
        failures += Check("枚举：UsageProvider 原始值往返", ProviderRoundtrip);
        failures += Check("数学：PercentageRemaining 25/100 = 25%", PercentageMath);
        failures += Check("DPAPI：字节数组保护/去保护往返", DpapiRoundtrip);

        Console.WriteLine(failures == 0 ? "selftest 结论：全部通过 ✓" : $"selftest 结论：{failures} 项失败 ✗");
        CliLog.Op("selftest", t0);
        return failures == 0 ? 0 : 1;
    }

    private static int Check(string name, Func<(bool Ok, string Detail)> assertion)
    {
        try
        {
            var (ok, detail) = assertion();
            Console.WriteLine($"  [{(ok ? "PASS" : "FAIL")}] {name}{(string.IsNullOrEmpty(detail) ? null : $" — {detail}")}");
            return ok ? 0 : 1;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"  [FAIL] {name} — 异常 {ex.GetType().Name}: {ex.Message}");
            return 1;
        }
    }

    private static (bool, string) UsageJsonRoundtrip()
    {
        const string json = """
            {"provider":"glm","remains":25,"total":100,"timestamp":"2026-09-27T10:00:00Z","models":[]}
            """;
        var parsed = JsonSerializer.Deserialize<UsageData>(json, QuotaJson.Default);
        var roundtripped = JsonSerializer.Deserialize<UsageData>(
            JsonSerializer.Serialize(parsed, QuotaJson.Default), QuotaJson.Default);
        // 注：UsageData 是 record，但 Models 为 IReadOnlyList（引用相等），全 record == 在此处恒 false；
        // 冒烟只钉标量字段与时间戳形状（完整契约等价性由 xUnit 差分金标测试覆盖）。
        var ok = parsed is not null && roundtripped is not null
            && parsed.Provider == roundtripped.Provider
            && parsed.Remains == roundtripped.Remains
            && parsed.Total == roundtripped.Total
            && parsed.Models.Count == roundtripped.Models.Count
            && parsed.Timestamp == roundtripped.Timestamp;
        return (ok, parsed is null ? "解析为 null" : $"remains={parsed.Remains} total={parsed.Total} ts={parsed.Timestamp:O}");
    }

    private static (bool, string) ProviderRoundtrip()
    {
        foreach (var provider in Enum.GetValues<UsageProvider>())
        {
            var back = UsageProviders.FromRawValue(provider.RawValue());
            if (back != provider)
            {
                return (false, $"{provider}.RawValue()={provider.RawValue()} 往返得到 {back}");
            }
        }

        return (true, $"{Enum.GetValues<UsageProvider>().Length} 个 provider 全部一致");
    }

    private static (bool, string) PercentageMath()
    {
        var data = JsonSerializer.Deserialize<UsageData>(
            """{"provider":"glm","remains":25,"total":100,"timestamp":"2026-09-27T10:00:00Z","models":[]}""",
            QuotaJson.Default)!;
        var pct = data.PercentageRemaining();
        return (Math.Abs(pct - 25.0) < 0.001, $"实际 {pct}");
    }

    private static (bool, string) DpapiRoundtrip()
    {
        var protector = new DpapiProtector();
        var plaintext = "aqb-cli-selftest-🔐"u8.ToArray();
        var encrypted = protector.Protect(plaintext);
        var decrypted = protector.Unprotect(encrypted);
        return (decrypted.AsSpan().SequenceEqual(plaintext), $"密文 {encrypted.Length} 字节");
    }
}
