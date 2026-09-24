// Swift 来源：AIQuotaBar/Services/Clash/ClashConnectionModels.swift — struct ClashActiveConnection（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashConnectionTests.swift

#nullable enable

using System;
using System.Collections.Generic;

namespace AIQuotaBar.Providers.Clash;

/// <summary>经 OpenAI 域名过滤并计算速率后的活跃连接（UI 展示形状；Duration/速率由计算器填好）。</summary>
public sealed record ClashActiveConnection(
    string Id,
    string Host,
    string? Process,
    string? Network,
    IReadOnlyList<string> Chains,
    DateTimeOffset? StartedAt,
    double Duration,
    double UploadSpeed,
    double DownloadSpeed)
{
    public string? PrimaryChain => Chains.Count > 0 ? Chains[0] : null;
}
