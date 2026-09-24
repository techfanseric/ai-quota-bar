// Swift 来源：AIQuotaBar/Services/Clash/ClashRouteSwitchHistoryStore.swift — struct ClashRouteSwitchRecord（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashRouteSwitchHistoryStoreTests.swift

#nullable enable

using System;

namespace AIQuotaBar.Providers.Clash;

/// <summary>一次线路切换记录（from → to + 时间）；Id 为随机 UUID。</summary>
public sealed record ClashRouteSwitchRecord(
    Guid Id,
    DateTimeOffset SwitchedAt,
    string FromRoute,
    string ToRoute);
