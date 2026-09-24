// Swift 来源：AIQuotaBar/Services/Clash/ClashModels.swift — struct ClashProxyHistory（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashRouteResolverTests.swift（经 ClashApiClient.LoadRouteSnapshotAsync）

#nullable enable

namespace AIQuotaBar.Providers.Clash;

/// <summary>单条代理延迟历史点（mihomo /proxies 响应内嵌字段；最后一条即当前延迟）。</summary>
public sealed record ClashProxyHistory(
    string? Time,
    int Delay);
