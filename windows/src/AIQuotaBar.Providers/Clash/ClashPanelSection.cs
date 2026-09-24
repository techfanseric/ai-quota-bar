// Swift 来源：AIQuotaBar/Services/Clash/ClashPanelDisplayStore.swift — enum ClashPanelSection: String, Codable（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashPanelDisplayStoreTests.swift

#nullable enable

using System.Text.Json.Serialization;

namespace AIQuotaBar.Providers.Clash;

/// <summary>右键 Clash 面板中的 OpenAI 分区（Swift raw value "routes" / "connections"）。</summary>
[JsonConverter(typeof(ClashPanelSectionJsonConverter))]
public enum ClashPanelSection
{
    Routes,
    Connections,
}
