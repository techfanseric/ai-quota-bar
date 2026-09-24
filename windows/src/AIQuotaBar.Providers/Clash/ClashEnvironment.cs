// Swift 来源：无（Windows 端新增——IClashEnvironment 的默认实现，读进程环境变量）。

#nullable enable

using System;

namespace AIQuotaBar.Providers.Clash;

/// <summary>基于 <see cref="Environment"/> 的路径根提供者。</summary>
public sealed class ClashEnvironment : IClashEnvironment
{
    public static ClashEnvironment Instance { get; } = new();

    public string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    public string AppData => Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
}
