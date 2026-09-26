// Swift 来源：无（Windows 端新增——分层铁律 NetArchTest 门禁，见 coding-conventions.md §4 TODO）。
// 规则依据：windows/docs/coding-conventions.md §4、移植计划 §7（依赖单向：
// App → Platform → Core、App → Providers → Core、Providers → Core）。
//
// NetArchTest 依赖匹配语义（NuGet 包 NetArchTest.Rules 1.3.2，NamespaceTree + Mono.Cecil
// 只读元数据）：按被检查类型的
// 全部类型引用（基类/接口/字段/属性/方法签名与方法体 IL 操作数）做"点分段前缀匹配"
//（等价 StartsWith，以命名空间段为粒度）。因此本文件里的依赖名均为命名空间前缀：
// - "AIQuotaBar.App" 拦截对 App 工程类型的引用。注意 App 工程 AssemblyName=AIQuotaBar
//   （见其 csproj），但其类型命名空间为 AIQuotaBar.App，按命名空间检测与程序集名解耦；
// - "System.Windows" 是拦截 WPF 的主匹配串：PresentationFramework 与 WindowsBase 两个
//   程序集的公开类型全部位于 System.Windows.* 命名空间下。按任务书原文同时保留
//   "WindowsBase" / "PresentationFramework" 两个程序集名（作为命名空间前缀无同名命名空间，
//   属冗余但无害）；另补 "System.Xaml"（System.Xaml.dll 的 XAML 类型独立命名空间）。

#nullable enable

using System;
using System.Linq;
using System.Reflection;

using AIQuotaBar.Core.Contracts;
using AIQuotaBar.Platform.Power;
using AIQuotaBar.Providers.Codex.Parsing;

using NetArchTest.Rules;

using Xunit;

namespace AIQuotaBar.Architecture.Tests;

public sealed class LayeredArchitectureTests
{
    // 被保护程序集的标记类型：各层 public 入口类型，稳定且随主工程编译。
    private static readonly Assembly CoreAssembly = typeof(UsageProvider).Assembly;
    private static readonly Assembly ProvidersAssembly = typeof(CodexUsageParser).Assembly;
    private static readonly Assembly PlatformAssembly = typeof(SystemPowerStatus).Assembly;

    [Fact]
    public void MarkerAssemblies_ResolveToExpectedAssemblyNames()
    {
        // 防空跑（vacuous green）：标记类型若被挪动程序集，下方所有规则会在错误的
        //（或近乎空的）程序集上运行并恒绿。先钉住三个程序集名，标记失效即失败。
        Assert.Equal("AIQuotaBar.Core", CoreAssembly.GetName().Name);
        Assert.Equal("AIQuotaBar.Providers", ProvidersAssembly.GetName().Name);
        Assert.Equal("AIQuotaBar.Platform", PlatformAssembly.GetName().Name);
    }

    // ------------------------------------------------------------------ Core（零上层/零 UI 依赖）

    [Fact]
    public void Core_ShouldNotDependOnOtherLayers()
    {
        AssertRule(
            "AIQuotaBar.Core 不得依赖 AIQuotaBar.Providers / Platform / App / Cli"
                + "（分层铁律：Core 是最底层，保住 macOS 本地 dotnet test 的并行开发根基）",
            Types.InAssembly(CoreAssembly)
                .ShouldNot()
                .HaveDependencyOnAny(
                    "AIQuotaBar.Providers",
                    "AIQuotaBar.Platform",
                    "AIQuotaBar.App",
                    "AIQuotaBar.Cli"));
    }

    [Fact]
    public void Core_ShouldNotDependOnWindowsUiFrameworks()
    {
        AssertRule(
            "AIQuotaBar.Core 不得依赖 WPF / WindowsBase / System.Xaml 等任何 UI 框架类型",
            Types.InAssembly(CoreAssembly)
                .ShouldNot()
                .HaveDependencyOnAny(
                    "System.Windows",
                    "WindowsBase",
                    "PresentationFramework",
                    "System.Xaml"));
    }

    // ------------------------------------------------------------------ Providers（零 Platform / UI 依赖）

    [Fact]
    public void Providers_ShouldNotDependOnUpperLayers()
    {
        AssertRule(
            "AIQuotaBar.Providers 不得依赖 AIQuotaBar.Platform / App / Cli"
                + "（Providers 只向下依赖 Core，平台能力一律经由 Core 定义的接口注入）",
            Types.InAssembly(ProvidersAssembly)
                .ShouldNot()
                .HaveDependencyOnAny(
                    "AIQuotaBar.Platform",
                    "AIQuotaBar.App",
                    "AIQuotaBar.Cli"));
    }

    [Fact]
    public void Providers_ShouldNotDependOnWindowsUiFrameworks()
    {
        AssertRule(
            "AIQuotaBar.Providers 不得依赖 WPF / WindowsBase 等 UI 框架类型（providers 可跨平台测试）",
            Types.InAssembly(ProvidersAssembly)
                .ShouldNot()
                .HaveDependencyOnAny(
                    "System.Windows",
                    "WindowsBase"));
    }

    // ------------------------------------------------------------------ Platform（零 App / Cli 依赖）

    [Fact]
    public void Platform_ShouldNotDependOnAppOrCli()
    {
        AssertRule(
            "AIQuotaBar.Platform 不得依赖 AIQuotaBar.App / Cli"
                + "（Platform 是被 App/Cli 消费的下层，反向依赖即成环）",
            Types.InAssembly(PlatformAssembly)
                .ShouldNot()
                .HaveDependencyOnAny(
                    "AIQuotaBar.App",
                    "AIQuotaBar.Cli"));
    }

    // ------------------------------------------------------------------ 失败信息格式化

    private static void AssertRule(string expectation, ConditionList conditions)
    {
        var result = conditions.GetResult();
        Assert.True(result.IsSuccessful, DescribeFailure(expectation, result));
    }

    private static string DescribeFailure(string expectation, TestResult result)
    {
        var failing = (result.FailingTypeNames ?? Array.Empty<string>())
            .OrderBy(static name => name, StringComparer.Ordinal)
            .ToArray();
        var sample = string.Join(", ", failing.Take(MaxTypesInFailureMessage));
        var overflow = failing.Length > MaxTypesInFailureMessage
            ? $" …（共 {failing.Length} 个，仅列出前 {MaxTypesInFailureMessage} 个）"
            : string.Empty;
        return $"应然：{expectation}。实然：{failing.Length} 个类型存在违规依赖 → {sample}{overflow}";
    }

    private const int MaxTypesInFailureMessage = 20;
}
