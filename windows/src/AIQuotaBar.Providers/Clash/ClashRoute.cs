// Swift 来源：AIQuotaBar/Services/Clash/ClashModels.swift — struct ClashRoute（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashRouteFilterTests.swift、ClashRouteResolverTests.swift

#nullable enable

namespace AIQuotaBar.Providers.Clash;

/// <summary>
/// 策略组内一条可切换线路。Swift 端 delay/isSelected 为 var（就地更新），
/// C# 端以 `with` 表达式等价更新（如测速后回填 Delay）。
/// </summary>
public sealed record ClashRoute(
    string Name,
    string Type,
    int? Delay,
    bool IsSelected)
{
    public string Id => Name;

    /// <summary>延迟可用（测速成功且大于 0）；0 表示超时，null 表示未测。</summary>
    public bool HasUsableDelay => Delay is > 0;
}
