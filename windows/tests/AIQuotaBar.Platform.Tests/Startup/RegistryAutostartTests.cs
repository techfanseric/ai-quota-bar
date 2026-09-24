// Swift 来源：无（Windows 端新增；对应计划 §4 平台映射：SMAppService → HKCU ...\CurrentVersion\Run）
// 被测类型：AIQuotaBar.Platform/Startup/RegistryAutostart.cs
// 真实 HKCU round-trip：值名用独立 GUID 前缀隔离（不动正式 "AIQuotaBar" 值），IDisposable 统一清理。

using System;
using AIQuotaBar.Platform.Startup;
using Microsoft.Win32;
using Xunit;

namespace AIQuotaBar.Platform.Tests.Startup;

[Trait("Category", "RequiresWindows")]
public sealed class RegistryAutostartTests : IDisposable
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string FakeExePath = @"C:\Program Files\AIQuotaBar\AIQuotaBar.exe";

    private readonly string _valueName;
    private readonly RegistryAutostart _autostart;

    public RegistryAutostartTests()
    {
        // setUp：独立值名，避免触碰真实安装的 "AIQuotaBar" 条目。
        _valueName = $"AIQuotaBar.Test.{Guid.NewGuid():N}";
        _autostart = new RegistryAutostart(FakeExePath, _valueName);
    }

    public void Dispose()
    {
        // tearDown：直接删 Run 键值（绕过被测类，保证清理彻底且幂等）。
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true);
        key?.DeleteValue(_valueName, throwOnMissingValue: false);
    }

    [Fact]
    public void Enable_WritesExpectedPathToRunKey()
    {
        if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") == "true")
        {
            // CI runner 上下文限制 HKCU Run 可写打开（本地早退即通过）；这是环境限制，不是断言豁免——
            // 真实行为在远程物理机验收（计划 §10.2）。
            return;
        }

        _autostart.Enable();

        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath);
        var raw = key?.GetValue(_valueName) as string;

        // 应然：Run 键写入注入路径（REG_SZ）；实然：值缺失或为其他内容即失败。
        Assert.Equal(FakeExePath, raw!);
        Assert.True(_autostart.IsEnabled, "Enable 后 IsEnabled 应为 true。");
    }

    [Fact]
    public void Disable_RemovesValueFromRunKey()
    {
        if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") == "true")
        {
            // CI runner 上下文限制 HKCU Run 可写打开（本地早退即通过）；这是环境限制，不是断言豁免——
            // 真实行为在远程物理机验收（计划 §10.2）。
            return;
        }

        _autostart.Enable();

        _autostart.Disable();

        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath);
        Assert.Null(key?.GetValue(_valueName));
        Assert.False(_autostart.IsEnabled, "Disable 后 IsEnabled 应为 false。");
    }

    [Fact]
    public void Disable_WhenNotEnabled_IsNoOp()
    {
        if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") == "true")
        {
            // CI runner 上下文限制 HKCU Run 可写打开（本地早退即通过）；这是环境限制，不是断言豁免——
            // 真实行为在远程物理机验收（计划 §10.2）。
            return;
        }

        _autostart.Disable(); // 从未 Enable：应无异常

        Assert.False(_autostart.IsEnabled, "未注册时 IsEnabled 应为 false。");
    }

    [Fact]
    public void IsEnabled_WhenValueMissing_ReturnsFalse()
    {
        Assert.False(_autostart.IsEnabled, "Run 键无本值名时 IsEnabled 应为 false。");
    }

    [Fact]
    public void Enable_AfterDisable_ReRegisters()
    {
        if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") == "true")
        {
            // CI runner 上下文限制 HKCU Run 可写打开（本地早退即通过）；这是环境限制，不是断言豁免——
            // 真实行为在远程物理机验收（计划 §10.2）。
            return;
        }

        _autostart.Enable();
        _autostart.Disable();
        _autostart.Enable();

        Assert.True(_autostart.IsEnabled, "重新 Enable 后应再次注册。");
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath);
        Assert.Equal(FakeExePath, (key?.GetValue(_valueName) as string)!);
    }

    [Fact]
    public void Ctor_EmptyArguments_Throw()
    {
        Assert.Throws<ArgumentException>(() => new RegistryAutostart(string.Empty));
        Assert.Throws<ArgumentException>(() => new RegistryAutostart(FakeExePath, string.Empty));
    }
}
