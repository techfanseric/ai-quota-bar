// Swift 来源：AIQuotaBar/Services/Clash/ClashModels.swift — struct ClashRouteSnapshot（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashRouteResolverTests.swift（经 ClashApiClient.LoadRouteSnapshotAsync）

#nullable enable

using System.Collections.Generic;

namespace AIQuotaBar.Providers.Clash;

/// <summary>策略组快照：组名、当前选中线路与（按 ClashRouteSorter 排序后的）线路列表。</summary>
public sealed record ClashRouteSnapshot(
    string GroupName,
    string? SelectedRouteName,
    IReadOnlyList<ClashRoute> Routes);
