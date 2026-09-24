// Swift 来源：AIQuotaBar/Services/Clash/ClashModels.swift — struct ClashRule（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashRouteResolverTests.swift

#nullable enable

namespace AIQuotaBar.Providers.Clash;

/// <summary>GET /rules 中的单条路由规则；Proxy 为命中后走到的策略（策略组名或 DIRECT 等）。</summary>
public sealed record ClashRule(
    string Type,
    string Payload,
    string Proxy);
