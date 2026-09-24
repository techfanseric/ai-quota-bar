// Swift 来源：AIQuotaBar/Services/Clash/ClashModels.swift — struct ClashControllerConfiguration（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashConfigurationDiscoveryTests.swift

#nullable enable

using System;

namespace AIQuotaBar.Providers.Clash;

/// <summary>
/// 经配置发现得到的 Clash 控制端连接参数：external controller 基地址（已限制为回环）、
/// 可选 secret、来源客户端名与配置文件位置。
/// </summary>
/// <param name="BaseUrl">
/// Swift URL.absoluteString 字符串形态（如 "http://127.0.0.1:9097"，**无尾斜杠**——
/// .NET Uri 对 authority-only URI 的 ToString/AbsoluteUri 会补 "/"，与 Swift 不一致，
/// 故以字符串承载，见 ClashConfigurationDiscovery.ControllerUrl）。
/// </param>
public sealed record ClashControllerConfiguration(
    string BaseUrl,
    string Secret,
    string ClientName,
    Uri ConfigUrl);
