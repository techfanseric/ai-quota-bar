// Swift 来源：Sources/CodexLocalUsageCore/UsageModels.swift（仓库根 Sources/ 的 App 自有 target
//   CodexLocalUsageCore——非 .dependencies/codexbar；struct UsageTokens：
//   total = input + output；valid 值域与签名格式）

#nullable enable

namespace AIQuotaBar.Providers.Codex.Parsing;

/// <summary>
/// 一次 token 计数（Swift: UsageTokens）。值域校验（valid）与签名格式与 Swift 一致，
/// 供本地用量去重与汇总。
/// </summary>
public sealed record CodexTokenUsageCounters(
    long Input,
    long Cached,
    long CacheWrite,
    long Output,
    long Reasoning)
{
    public const long MaxTokenCount = 1_000_000_000_000;

    /// <summary>Swift: total = input + output。</summary>
    public long Total => Input + Output;

    /// <summary>
    /// Swift: valid —— 各字段 0..1e12，且 cached + cacheWrite ≤ input、reasoning ≤ output。
    /// </summary>
    public bool IsValid =>
        Input >= 0 && Input <= MaxTokenCount &&
        Cached >= 0 && Cached <= MaxTokenCount &&
        CacheWrite >= 0 && CacheWrite <= MaxTokenCount &&
        Output >= 0 && Output <= MaxTokenCount &&
        Reasoning >= 0 && Reasoning <= MaxTokenCount &&
        Cached + CacheWrite <= Input &&
        Reasoning <= Output;

    /// <summary>Swift: signature = "input:cached:cacheWrite:output:reasoning"。</summary>
    public string Signature => $"{Input}:{Cached}:{CacheWrite}:{Output}:{Reasoning}";
}
