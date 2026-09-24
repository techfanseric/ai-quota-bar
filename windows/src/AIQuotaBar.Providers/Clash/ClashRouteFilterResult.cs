// Swift 来源：AIQuotaBar/Services/Clash/ClashRouteFilter.swift — struct ClashRouteFilterResult（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashRouteFilterTests.swift

#nullable enable

using System.Collections.Generic;

namespace AIQuotaBar.Providers.Clash;

/// <summary>路由过滤结果；ErrorMessage 仅在正则模式解析失败时非空（此时 Routes 为空）。</summary>
public sealed record ClashRouteFilterResult(
    IReadOnlyList<ClashRoute> Routes,
    string? ErrorMessage);
