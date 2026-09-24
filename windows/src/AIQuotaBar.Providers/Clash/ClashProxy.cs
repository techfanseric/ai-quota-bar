// Swift 来源：AIQuotaBar/Services/Clash/ClashModels.swift — struct ClashProxy（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashRouteResolverTests.swift

#nullable enable

using System.Collections.Generic;

namespace AIQuotaBar.Providers.Clash;

/// <summary>
/// /proxies 中的单个代理（或策略组）。策略组：Type == "Selector" 且 All 非空；
/// Now 为组内当前选中项，History 最后一条为最近一次测速延迟。
/// </summary>
public sealed record ClashProxy(
    string? Name,
    string Type,
    string? Now,
    IReadOnlyList<string>? All,
    IReadOnlyList<ClashProxyHistory>? History);
