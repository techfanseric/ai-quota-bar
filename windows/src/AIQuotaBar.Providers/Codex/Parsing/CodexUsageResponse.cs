// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthUsageFetcher.swift
//   （struct CodexUsageResponse 及其嵌套类型：损失容忍解码语义逐分支镜像——由
//    CodexUsageParser.ParseUsageResponse 构造；契约样本：windows/contracts/fixtures/codex/usage-response-*.json）
// 对应测试：AIQuotaBar.Providers.Tests/Codex/CodexUsageParserTests.cs
//
// 布局说明：Swift 的嵌套类型 RateLimitDetails / AdditionalRateLimit / CreditDetails /
// SpendControlLimitSnapshot 在 C# 侧提升到命名空间级——record 的主构造参数列表/基类列表
// 不能引用自身嵌套类型（类型声明未完成、嵌套成员不可见，CS0246）。WindowSnapshot 仍嵌套：
// CodexUsageResponse 自身参数列表不直接引用它（兄弟嵌套引用在成员作用域，合法），且本文件
// 中 CodexUsageResponse 先于命名空间级类型声明，嵌套成员对外可见。

#nullable enable

using System.Collections.Generic;

namespace AIQuotaBar.Providers.Codex.Parsing;

/// <summary>
/// wham/usage（OAuth/PAT 同路径）响应的解码结果（Swift: CodexUsageResponse）。
/// PlanType 保留线上原串（Swift 的 PlanType 枚举对未知值原样保留 rawValue，此处等价为 string）。
/// </summary>
public sealed record CodexUsageResponse(
    string? AccountId,
    string? PlanType,
    RateLimitDetails? RateLimit,
    CreditDetails? Credits,
    SpendControlLimitSnapshot? IndividualLimit,
    SpendControlLimitSnapshot? SpendControlIndividualLimit,
    bool SpendControlPresent,
    IReadOnlyList<AdditionalRateLimit>? AdditionalRateLimits,
    bool AdditionalRateLimitsDecodeFailed)
{
    /// <summary>Swift: rateLimit?.hasWindowDecodeFailure —— 主/周窗口解码有损。</summary>
    public bool HasWindowDecodeFailure => RateLimit?.HasWindowDecodeFailure == true;

    /// <summary>Swift: resolvedIndividualLimit —— 限额来源优先级：根级 → rate_limit → spend_control。</summary>
    public SpendControlLimitSnapshot? ResolvedIndividualLimit =>
        IndividualLimit ?? RateLimit?.IndividualLimit ?? SpendControlIndividualLimit;

    /// <summary>单个窗口快照（Swift: WindowSnapshot）。三个整数字段齐全才可解码。</summary>
    public sealed record WindowSnapshot(int UsedPercent, int ResetAt, int LimitWindowSeconds);
}

/// <summary>
/// rate_limit 对象（Swift: CodexUsageResponse.RateLimitDetails）。primary/secondary 任一解码
/// 失败时该窗口置 null 并记录 <see cref="PrimaryWindowDecodeFailed"/> /
/// <see cref="SecondaryWindowDecodeFailed"/>（供 dataConfidence=unknown 判定），另一个窗口不受影响。
/// </summary>
public sealed record RateLimitDetails(
    CodexUsageResponse.WindowSnapshot? PrimaryWindow,
    CodexUsageResponse.WindowSnapshot? SecondaryWindow,
    SpendControlLimitSnapshot? IndividualLimit,
    bool PrimaryWindowDecodeFailed,
    bool SecondaryWindowDecodeFailed)
{
    public bool HasWindowDecodeFailure => PrimaryWindowDecodeFailed || SecondaryWindowDecodeFailed;
}

/// <summary>
/// additional_rate_limits 的单个条目（Swift: CodexUsageResponse.AdditionalRateLimit）。
/// rate_limit 解码失败置 null 并记 <see cref="RateLimitDecodeFailed"/>。
/// </summary>
public sealed record AdditionalRateLimit(
    string? LimitName,
    string? MeteredFeature,
    RateLimitDetails? RateLimit,
    bool RateLimitDecodeFailed)
{
    public bool HasWindowDecodeFailure => RateLimitDecodeFailed || (RateLimit?.HasWindowDecodeFailure == true);
}

/// <summary>
/// credits 对象（Swift: CodexUsageResponse.CreditDetails）。has_credits/unlimited 缺失或类型
/// 不符按 false；balance 为数字，或可解析为 double 的字符串（"0"），其余（[]/对象/bool）为 null。
/// </summary>
public sealed record CreditDetails(bool HasCredits, bool Unlimited, double? Balance);

/// <summary>
/// 个人月度限额（Swift: CodexUsageResponse.SpendControlLimitSnapshot）。数值字段走灵活解码
/// （数字/字符串双形态），resets_at 兼任 wham/usage 的 reset_at 拼写。
/// </summary>
public sealed record SpendControlLimitSnapshot(
    double? Limit,
    double? Used,
    double? RemainingPercent,
    int? ResetsAt);
