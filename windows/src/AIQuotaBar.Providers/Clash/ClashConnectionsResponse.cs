// Swift 来源：AIQuotaBar/Services/Clash/ClashConnectionModels.swift — struct ClashConnectionsResponse（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashConnectionTests.swift — testConnectionsResponseDecodesMihomoFields
// fixtures：windows/contracts/fixtures/clash/connections-response-mihomo.json

#nullable enable

using System.Collections.Generic;

namespace AIQuotaBar.Providers.Clash;

/// <summary>
/// GET /connections（及 WebSocket 流帧）响应。memory 等未知字段容忍（默认行为），
/// downloadTotal/uploadTotal 可缺失。
/// </summary>
public sealed record ClashConnectionsResponse(
    long? DownloadTotal,
    long? UploadTotal,
    IReadOnlyList<ClashConnectionRecord> Connections);
