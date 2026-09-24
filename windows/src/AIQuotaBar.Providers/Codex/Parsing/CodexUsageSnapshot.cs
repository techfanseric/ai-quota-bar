// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/UsageFetcher.swift（struct UsageSnapshot，
//   裁剪为 Codex 消费子集：provider 专属字段（deepseek/opencodego/mistral/...）按 S1 二级裁剪建议删除；
//   codexResetCredits 不进入该中间表示，由解析层单独返回，见 CodexUsageParser.ParseRateLimitResetCredits）

#nullable enable

using System;
using System.Collections.Generic;

namespace AIQuotaBar.Providers.Codex.Parsing;

/// <summary>
/// 跨源统一的 Codex 用量快照（Swift: UsageSnapshot 的 Codex 子集）。既是 usage 响应映射的
/// 中间表示，也是 usage-snapshot 线上形态（camelCase + ISO 8601 日期）的反序列化目标。
/// </summary>
/// <param name="Primary">主（5h）窗口；null 表示无。</param>
/// <param name="Secondary">周窗口；null 表示无。</param>
/// <param name="Tertiary">第三窗口（Codex 当前不产生，保留线上形状）。</param>
/// <param name="ExtraRateWindows">命名额外窗口；null 表示字段缺失（与空列表区分，Swift encodeIfPresent 同语义）。</param>
/// <param name="ProviderCost">可选花费/余额快照。</param>
/// <param name="UpdatedAt">快照时间。</param>
/// <param name="Identity">账号身份。</param>
/// <param name="DataConfidence">数据置信度（窗口解码有损时 Unknown）。</param>
public sealed record CodexUsageSnapshot(
    CodexRateWindow? Primary,
    CodexRateWindow? Secondary,
    CodexRateWindow? Tertiary,
    IReadOnlyList<CodexNamedRateWindow>? ExtraRateWindows,
    CodexProviderCostSnapshot? ProviderCost,
    DateTimeOffset UpdatedAt,
    CodexProviderIdentity? Identity = null,
    CodexDataConfidence DataConfidence = CodexDataConfidence.Unknown)
{
    public bool HasRateLimitWindows =>
        Primary is not null || Secondary is not null || Tertiary is not null ||
        (ExtraRateWindows is { Count: > 0 });
}
