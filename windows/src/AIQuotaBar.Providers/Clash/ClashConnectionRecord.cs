// Swift 来源：AIQuotaBar/Services/Clash/ClashConnectionModels.swift — struct ClashConnectionRecord（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashConnectionTests.swift

#nullable enable

using System.Collections.Generic;

namespace AIQuotaBar.Providers.Clash;

/// <summary>单条连接记录；Start 为 mihomo 原始字符串（微秒精度 ISO 8601），经 ClashConnectionDateParser 解析。</summary>
public sealed record ClashConnectionRecord(
    string Id,
    long Download,
    long Upload,
    IReadOnlyList<string> Chains,
    string? Rule,
    string? RulePayload,
    string Start,
    ClashConnectionMetadata Metadata);
