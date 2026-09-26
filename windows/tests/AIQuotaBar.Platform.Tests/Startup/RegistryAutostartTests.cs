// Swift 来源：无（Windows 端新增；对应计划 §4 平台映射：SMAppService → HKCU ...\CurrentVersion\Run）
// 被测类型：AIQuotaBar.Platform/Startup/RegistryAutostart.cs
// 真实 HKCU round-trip：值名用独立 GUID 前缀隔离（不动正式 "AIQuotaBar" 值），IDisposable 统一清理（约定 §7.2）。
// 环境守卫（计划 §0 先例「注册表可写测试在 CI 环境守卫跳过」）：构造时对 Run 键做真实「写 + 删」探测，
// 失败则写路径用例早退通过并输出原因（环境限制非断言豁免，真实行为在远程物理机验收 §10.2）。
// 较 W1 波的 GITHUB_ACTIONS 环境变量嗅探，主动探测能覆盖 GitHub 之外的不可写会话。

#nullable enable

using System;
using AIQuotaBar.Platform.Startup;
using Microsoft.Win32;
using Xunit;
using Xunit.Abstractions;

namespace AIQuotaBar.Platform.Tests.Startup;

[Trait("Category", "RequiresWindows")]
public sealed class RegistryAutostartTests : IDisposable
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string CommandLine = @"""C:\Program Files\AIQuotaBar\AIQuotaBar.exe"" --hidden";

    private readonly ITestOutputHelper _output;
    private readonly string _valueName;
    private readonly RegistryAutostart _autostart;
    private readonly bool _hkcuRunWritable;

    public RegistryAutostartTests(ITestOutputHelper output)
    {
        // setUp：独立 GUID 值名，避免触碰真实安装的 "AIQuotaBar" 条目。
        _output = output;
        _valueName = $"AIQuotaBar.Test.{Guid.NewGuid():N}";
        _autostart = new RegistryAutostart(_valueName);
        _hkcuRunWritable = ProbeHkcuRunWritable();
    }

    public void Dispose()
    {
        // tearDown：绕过被测类直接删 Run 键值（幂等删除；含探测值残留保险），保证清理彻底。
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true);
        key?.DeleteValue(_valueName, throwOnMissingValue: false);
        key?.DeleteValue(_valueName + ".probe", throwOnMissingValue: false);
    }

    [Fact]
    public void Enable_ThenTryGet_ReturnsCommandLine()
    {
        if (!_hkcuRunWritable)
        {
            return; // 环境守卫早退（原因见探测输出），非断言豁免。
        }

        _autostart.Enable(CommandLine);

        var found = _autostart.TryGetEnabledCommand(out var command);

        // 应然：注册后读回写入的完整命令行（含引号与参数）；实然：false 或命令行不符即失败。
        Assert.True(found, "Enable 后 TryGetEnabledCommand 应返回 true。");
        Assert.Equal(CommandLine, command);
    }

    [Fact]
    public void Enable_Twice_OverwritesWithLatestCommandLine()
    {
        if (!_hkcuRunWritable)
        {
            return; // 环境守卫早退（原因见探测输出），非断言豁免。
        }

        _autostart.Enable(@"""C:\AIQuotaBar\old.exe"" --hidden");
        _autostart.Enable(@"""C:\AIQuotaBar\new.exe"" --show");

        var found = _autostart.TryGetEnabledCommand(out var command);

        // 应然：重复注册以最后一次为准（Run 键同名值覆盖，对应 SMAppService 幂等重注册语义）。
        Assert.True(found, "重复 Enable 后 TryGetEnabledCommand 应返回 true。");
        Assert.Equal(@"""C:\AIQuotaBar\new.exe"" --show", command);
    }

    [Fact]
    public void Disable_RegisteredValue_ReturnsTrueAndClears()
    {
        if (!_hkcuRunWritable)
        {
            return; // 环境守卫早退（原因见探测输出），非断言豁免。
        }

        _autostart.Enable(CommandLine);

        var disabled = _autostart.Disable();

        // 应然：已注册的值删除返回 true，且随后读不到；实然：false 或残留即失败。
        Assert.True(disabled, "已注册的值 Disable 应返回 true。");
        Assert.False(_autostart.TryGetEnabledCommand(out var command), "Disable 后 TryGetEnabledCommand 应返回 false。");
        Assert.Null(command);
    }

    [Fact]
    public void Disable_WhenNotRegistered_ReturnsFalse()
    {
        // GUID 值名从未注册：Disable 走只读探测早退路径，不触碰可写打开，无需环境守卫。
        var disabled = _autostart.Disable();

        // 应然：不存在的值删除返回 false（幂等语义，非异常）。
        Assert.False(disabled, "未注册的值 Disable 应返回 false。");
    }

    [Fact]
    public void Disable_Twice_SecondCallReturnsFalse()
    {
        if (!_hkcuRunWritable)
        {
            return; // 环境守卫早退（原因见探测输出），非断言豁免。
        }

        _autostart.Enable(CommandLine);

        var first = _autostart.Disable();
        var second = _autostart.Disable();

        // 应然：首次（值存在）true，再次（值已删）false——幂等。
        Assert.True(first, "首次 Disable（值存在）应返回 true。");
        Assert.False(second, "再次 Disable（值已删）应返回 false。");
    }

    [Fact]
    public void TryGet_WhenNotRegistered_ReturnsFalseAndNullCommand()
    {
        var found = _autostart.TryGetEnabledCommand(out var command);

        // 应然：GUID 值名从未写入，返回 false 且出参 null（只读路径，无需环境守卫）；
        // 实然：true 即测试隔离失败（值名冲突或残留）。
        Assert.False(found, "未注册时 TryGetEnabledCommand 应返回 false。");
        Assert.Null(command);
    }

    [Fact]
    public void Ctor_EmptyValueName_Throws()
    {
        Assert.Throws<ArgumentException>(() => new RegistryAutostart(string.Empty));
    }

    [Fact]
    public void Enable_EmptyCommandLine_Throws()
    {
        // 参数校验先于注册表访问：无可写环境也能验证。
        Assert.Throws<ArgumentException>(() => _autostart.Enable(string.Empty));
    }

    /// <summary>
    /// 环境守卫探测：对 HKCU Run 键做真实「写 + 删」。
    /// 成功 → 本测试类写路径用例照常执行；失败（部分 CI runner / 特殊会话不可写）→
    /// 写路径用例早退通过并输出原因（环境限制非断言豁免，计划 §0 / §10.2）。
    /// </summary>
    private bool ProbeHkcuRunWritable()
    {
        var probeName = _valueName + ".probe";
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true);
            if (key is null)
            {
                _output.WriteLine("HKCU Run 写探测失败：CreateSubKey 返回 null，写路径用例按环境守卫早退。");
                return false;
            }

            key.SetValue(probeName, "probe", RegistryValueKind.String);
            key.DeleteValue(probeName, throwOnMissingValue: false);
            return true;
        }
        catch (Exception ex)
        {
            _output.WriteLine($"HKCU Run 写探测失败（{ex.GetType().Name}: {ex.Message}），写路径用例按环境守卫早退。");
            return false;
        }
    }
}
