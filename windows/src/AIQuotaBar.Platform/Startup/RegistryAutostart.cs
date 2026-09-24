// Swift 来源：无（Windows 端新增；对应计划 §4 平台映射：SMAppService（macOS 开机自启）→ HKCU\Software\Microsoft\Windows\CurrentVersion\Run）
// 对应测试：windows/tests/AIQuotaBar.Platform.Tests/Startup/RegistryAutostartTests.cs
//
// 说明：使用 Microsoft.Win32.Registry（net8.0-windows TFM 内置，无需 NuGet 包）。
// 业务设置本身不进注册表（计划 §4「UserDefaults → %APPDATA%\AIQuotaBar\settings.json」），
// 注册表只承载自启动这一项 Windows 惯例机制。
// 可写访问统一走 CreateSubKey(path, writable:true) 的「打开或创建」形态：OpenSubKey(path, true)
// 对「键不存在」与「拒绝访问」一律返回 null 且不抛底层原因（.NET RegistryKey 行为），失败不可诊断；
// CreateSubKey 键缺失即创建、拒绝访问则抛 Win32Exception——原因可见（见 OpenRunKeyWritable）。

#nullable enable

using System;
using System.ComponentModel;
using Microsoft.Win32;

namespace AIQuotaBar.Platform.Startup;

/// <summary>
/// 开机自启管理：HKCU <c>Software\Microsoft\Windows\CurrentVersion\Run</c> 键的读/写/删。
/// </summary>
/// <remarks>
/// macOS 端对应物：SMAppService（launchd 注册）。用户级 HKCU 无需管理员权限；
/// 可执行文件路径由构造注入（安装目录由发布形态决定，Velopack/Inno 布局可能不同，计划 §5.5）。
/// MSIX 打包时 Run 键会失效，届时在 App 层换 StartupTask 实装（计划 §13 D4），本类接口形状不变。
/// </remarks>
public sealed class RegistryAutostart
{
    /// <summary>Run 键默认值名（正式安装的应用应使用此值）。</summary>
    public const string DefaultValueName = "AIQuotaBar";

    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";

    private readonly string _executablePath;
    private readonly string _valueName;

    /// <param name="executablePath">自启动时启动的可执行文件完整路径（测试注入假路径即可，值不会被拉起）。</param>
    /// <param name="valueName">Run 键值名；正式用途默认 <see cref="DefaultValueName"/>，测试用独立名隔离清理。</param>
    /// <exception cref="ArgumentException">任一参数为空。</exception>
    public RegistryAutostart(string executablePath, string valueName = DefaultValueName)
    {
        if (string.IsNullOrEmpty(executablePath))
        {
            throw new ArgumentException("可执行文件路径不可为空。", nameof(executablePath));
        }

        if (string.IsNullOrEmpty(valueName))
        {
            throw new ArgumentException("Run 键值名不可为空。", nameof(valueName));
        }

        _executablePath = executablePath;
        _valueName = valueName;
    }

    /// <summary>当前是否已注册自启动（Run 键中存在本值名）。</summary>
    public bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath);
            return key?.GetValue(_valueName) is not null;
        }
    }

    /// <summary>
    /// 注册自启动：Run 键写入 <see cref="RegistryValueKind.String"/> 值（REG_SZ）= 注入路径。
    /// </summary>
    /// <exception cref="InvalidOperationException">
    /// 打开/创建 Run 键失败（如拒绝访问）；inner 为底层 <see cref="Win32Exception"/>，消息含 Win32 错误码。
    /// </exception>
    public void Enable()
    {
        using var key = OpenRunKeyWritable();
        key.SetValue(_valueName, _executablePath, RegistryValueKind.String);
    }

    /// <summary>
    /// 取消自启动：删除 Run 键值。值不存在时为无害幂等操作。
    /// </summary>
    /// <exception cref="InvalidOperationException">
    /// 打开/创建 Run 键失败（如拒绝访问）；inner 为底层 <see cref="Win32Exception"/>，消息含 Win32 错误码。
    /// </exception>
    public void Disable()
    {
        using var key = OpenRunKeyWritable();
        key.DeleteValue(_valueName, throwOnMissingValue: false);
    }

    /// <summary>
    /// 以「打开或创建」语义取 Run 键可写句柄（键不存在时创建——标准可写访问形态；
    /// 拒绝访问等真实失败抛 <see cref="InvalidOperationException"/>，inner 携带底层 Win32 错误）。
    /// </summary>
    private static RegistryKey OpenRunKeyWritable()
    {
        try
        {
            return Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true)
                ?? throw new InvalidOperationException(
                    $"创建/打开 HKCU {RunKeyPath}（可写）失败：CreateSubKey 返回 null。");
        }
        catch (Win32Exception ex)
        {
            // 到这里说明不是「键不存在」（缺失会被创建），而是拒绝访问等真实失败：
            // inner 保留底层错误、消息带错误码，杜绝吞因。
            throw new InvalidOperationException(
                $"创建/打开 HKCU {RunKeyPath}（可写）失败：Win32 错误 {ex.NativeErrorCode}（{ex.Message}）。",
                ex);
        }
    }
}
