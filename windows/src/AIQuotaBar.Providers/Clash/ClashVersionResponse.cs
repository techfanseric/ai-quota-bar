// Swift 来源：AIQuotaBar/Services/Clash/ClashModels.swift — struct ClashVersionResponse（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashApiClientTests.cs（fixtures 缺 /version 样本，见 contracts/fixtures/README 缺口清单）

#nullable enable

namespace AIQuotaBar.Providers.Clash;

/// <summary>GET /version 响应；Meta 标记是否为 mihomo 等 meta 内核。</summary>
public sealed record ClashVersionResponse(
    bool? Meta,
    string Version);
