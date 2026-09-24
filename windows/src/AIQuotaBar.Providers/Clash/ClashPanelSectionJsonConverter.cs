// Swift 来源：AIQuotaBar/Services/Clash/ClashPanelDisplayStore.swift — enum ClashPanelSection 的
// String raw value 编解码（v1.28.1）；C# 端手写 converter（QuotaJson 冻结，不可全局注册，
// 经 [JsonConverter] 特性挂到枚举上——与 Core 的 UsageProviderJsonConverter 同一模式）。

#nullable enable

using System;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AIQuotaBar.Providers.Clash;

/// <summary>ClashPanelSection 的 Swift raw value 线格式："routes" / "connections"。</summary>
public sealed class ClashPanelSectionJsonConverter : JsonConverter<ClashPanelSection>
{
    public static ClashPanelSectionJsonConverter Instance { get; } = new();

    public override ClashPanelSection Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var raw = reader.GetString();
        return raw switch
        {
            "routes" => ClashPanelSection.Routes,
            "connections" => ClashPanelSection.Connections,
            _ => throw new JsonException($"Unknown ClashPanelSection raw value '{raw}'."),
        };
    }

    public override void Write(Utf8JsonWriter writer, ClashPanelSection value, JsonSerializerOptions options)
    {
        writer.WriteStringValue(value switch
        {
            ClashPanelSection.Routes => "routes",
            ClashPanelSection.Connections => "connections",
            _ => throw new ArgumentOutOfRangeException(nameof(value), value, null),
        });
    }
}
