// Swift 来源：AIQuotaBar/Services/Clash/ClashModels.swift — struct ClashRulesResponse（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashRouteResolverTests.swift

#nullable enable

using System.Collections.Generic;

namespace AIQuotaBar.Providers.Clash;

/// <summary>GET /rules 响应。</summary>
public sealed record ClashRulesResponse(
    IReadOnlyList<ClashRule> Rules);
