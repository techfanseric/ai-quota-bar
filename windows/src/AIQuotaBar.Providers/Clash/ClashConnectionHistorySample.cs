// Swift 来源：AIQuotaBar/Services/Clash/ClashConnectionModels.swift — struct ClashConnectionHistorySample（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashConnectionTests.swift

#nullable enable

using System;
using System.Collections.Generic;

namespace AIQuotaBar.Providers.Clash;

/// <summary>
/// 一分钟的活跃连接时序样本：只落聚合年龄（不落 host/process 等明细，
/// 持久化文件因此不含 openai.com/process/destinationIP 字样）。
/// </summary>
public sealed record ClashConnectionHistorySample(
    DateTimeOffset Timestamp,
    IReadOnlyList<double> ConnectionAges)
{
    public DateTimeOffset Id => Timestamp;

    public int ConnectionCount => ConnectionAges.Count;
}
