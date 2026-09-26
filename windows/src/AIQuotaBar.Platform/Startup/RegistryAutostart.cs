// Swift 来源：无（Windows 端新增；对应计划 §4 平台映射：SMAppService（macOS 开机自启）→ HKCU\Software\Microsoft\Windows\CurrentVersion\Run）
// 对应测试：windows/tests/AIQuotaBar.Platform.Tests/Startup/RegistryAutostartTests.cs
//
// 说明：使用 Microsoft.Win32.Registry（net8.0-windows TFM 内置，无需 NuGet 包）。
// 业务设置本身不进注册表（计划 §4「UserDefaults → %APPDATA%\AIQuotaBar\settings.json」），
// 注册表只承载自启动这一项 Windows 惯例机制。
// 可写访问统一走 CreateSubKey(path, writable:true) 的「打开或创建」形态：OpenSubKey(path, true)
// 对「键不存在」与「拒绝访问」一律返回 null 且不抛底层原因（.NET RegistryKey 行为），失败不可诊断；
// CreateSubKey 键缺失即创建、拒绝访问则抛 Win32Exception。
// 异常策略：注册表不可写环境（部分 CI runner / 特殊会话）抛出的底层异常（Win32Exception 等）
// 保持原始异常透传、不在本层包装吞因——上层有环境守卫惯例（计划 §0：写探测失败早退，真实行为物理机验收）。

#nullable enable

using System;
using System.ComponentModel;
using Microsoft.Win32;

namespace AIQuotaBar.Platform.Startup;

/// <summary>
/// 开机自启管理：HKCU <c>Software\Microsoft\Windows\CurrentVersion\Run</c> 键的读/写/删。
/// </summary>
/// <remarks>
/// macOS 端对应物：SMAppService（launchd 注册，计划 §4 映射表）。用户级 HKCU 无需管理员权限；
/// 自启动命令行由 <see cref="Enable"/> 调用方注入（可执行文件路径 + 启动参数，如 <c>--hidden</c>；
/// 安装目录由发布形态决定，Velopack/Inno 布局可能不同，计划 §5.5）。
/// MSIX 打包时 Run 键会失效，届时在 App 层换 StartupTask 实装（计划 §13 D4），本类接口形状不变。
/// </remarks>
public sealed class RegistryAutostart
{
    /// <summary>Run 键默认值名（正式安装的应用应使用此值）。</summary>
    public const string DefaultValueName = "AIQuotaBar";

    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";

    private readonly string _valueName;

    /// <param name="valueName">Run 键值名；正式用途默认 <see cref="DefaultValueName"/>，测试注入独立名隔离清理。</param>
    /// <exception cref="ArgumentException">值名为空。</exception>
    public RegistryAutostart(string valueName = DefaultValueName)
    {
        if (string.IsNullOrEmpty(valueName))
        {
            throw new ArgumentException("Run 键值名不可为空。", nameof(valueName));
        }

        _valueName = valueName;
    }

    /// <summary>
    /// 注册自启动：Run 键写入 <see cref="RegistryValueKind.String"/> 值（REG_SZ）= <paramref name="commandLine"/>。
    /// </summary>
    /// <param name="commandLine">开机拉起的完整命令行（可执行文件路径，可含引号与启动参数）。</param>
    /// <exception cref="ArgumentException">命令行为空。</exception>
    /// <exception cref="Win32Exception">注册表不可写（如权限被拒）——原始异常透传，不吞（上层环境守卫负责诊断）。</exception>
    public void Enable(string commandLine)
    {
        if (string.IsNullOrEmpty(commandLine))
        {
            throw new ArgumentException("自启动命令行不可为空。", nameof(commandLine));
        }

        using var key = OpenRunKeyWritable();
        key.SetValue(_valueName, commandLine, RegistryValueKind.String);
    }

    /// <summary>
    /// 取消自启动：删除 Run 键值。
    /// </summary>
    /// <returns>值原本存在且已删除返回 true；不存在返回 false（幂等语义，非异常）。</returns>
    /// <exception cref="Win32Exception">注册表不可写——原始异常透传，不吞（上层环境守卫负责诊断）。</exception>
    public bool Disable()
    {
        // 先只读探测值是否存在：不存在直接 false，既不触碰可写打开，也不会因删除而创建空 Run 键。
        using (var readKey = Registry.CurrentUser.OpenSubKey(RunKeyPath))
        {
            if (readKey?.GetValue(_valueName) is null)
            {
                return false;
            }
        }

        using var key = OpenRunKeyWritable();
        key.DeleteValue(_valueName, throwOnMissingValue: false);
        return true;
    }

    /// <summary>
    /// 读取当前注册的自启动命令行。
    /// </summary>
    /// <param name="command">已注册的命令行；未注册（或值非 REG_SZ 字符串）时为 null。</param>
    /// <returns>已注册返回 true；未注册返回 false。</returns>
    public bool TryGetEnabledCommand(out string? command)
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath);
        command = key?.GetValue(_valueName) as string;
        return command is not null;
    }

    /// <summary>
    /// 以「打开或创建」语义取 Run 键可写句柄（键不存在时创建——HKCU 下的标准可写访问形态）。
    /// 不做任何 catch 包装：拒绝访问等真实失败时 <see cref="Registry.CurrentUser"/> 抛出的
    /// <see cref="Win32Exception"/> 原样上抛（透传不吞，上层环境守卫惯例依赖可诊断的底层错误）。
    /// </summary>
    private static RegistryKey OpenRunKeyWritable()
    {
        // ?? throw 仅防御文档上「不该发生」的 null 返回（无异常可吞，给出可诊断消息即可）。
        return Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true)
            ?? throw new InvalidOperationException($"打开/创建 HKCU {RunKeyPath}（可写）失败：CreateSubKey 返回 null。");
    }
}
