// Swift 来源：AIQuotaBar/Services/Clash/ClashConnectionModels.swift — struct ClashConnectionActivitySnapshot（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashConnectionTests.swift

#nullable enable

using System;
using System.Collections.Generic;

namespace AIQuotaBar.Providers.Clash;

/// <summary>一次 /connections 采样后的聚合快照：过滤后的活跃连接与总上传/下载速率。</summary>
public sealed record ClashConnectionActivitySnapshot(
    DateTimeOffset ObservedAt,
    IReadOnlyList<ClashActiveConnection> Connections,
    double UploadSpeed,
    double DownloadSpeed);
