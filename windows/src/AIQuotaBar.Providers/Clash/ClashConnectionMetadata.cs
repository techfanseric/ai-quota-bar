// Swift 来源：AIQuotaBar/Services/Clash/ClashConnectionModels.swift — struct ClashConnectionMetadata（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashConnectionTests.swift — testConnectionsResponseDecodesMihomoFields

#nullable enable

using System.Text.Json.Serialization;

namespace AIQuotaBar.Providers.Clash;

/// <summary>单条连接的元数据。destinationIP 保持 Swift Codable 键（大写 IP）上线。</summary>
public sealed record ClashConnectionMetadata(
    string? Network,
    string? Type,
    [property: JsonPropertyName("destinationIP")] string? DestinationIp,
    string? Host,
    string? Process,
    string? ProcessPath,
    string? RemoteDestination,
    string? SniffHost);
