// Swift 来源：无（Windows 端新增——对应 Swift ClashConfigurationDiscovery 注入 homeDirectory: URL
// 的测试钩子；Windows 端路径根扩展为 Home + AppData 两个根，供配置发现定位候选目录）。

#nullable enable

namespace AIQuotaBar.Providers.Clash;

/// <summary>Clash 配置发现的路径根抽象（%USERPROFILE% / %APPDATA%），测试注入桩实现。</summary>
public interface IClashEnvironment
{
    /// <summary>%USERPROFILE%（对应 Swift 注入的 homeDirectory）。</summary>
    string Home { get; }

    /// <summary>%APPDATA%（Roaming）；Clash Verge Rev 的 Windows 数据目录根。</summary>
    string AppData { get; }
}
