// Swift 来源：AIQuotaBar/Services/Clash/ClashModels.swift — struct ClashProxiesResponse（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashRouteResolverTests.swift

#nullable enable

using System.Collections.Generic;

namespace AIQuotaBar.Providers.Clash;

/// <summary>GET /proxies 响应：按名称索引的全部代理与策略组。</summary>
public sealed record ClashProxiesResponse(
    Dictionary<string, ClashProxy> Proxies);
