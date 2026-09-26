// Swift 来源：无（Windows 测试辅助的守卫测试——钉住公共 fixtures 加载器的定位约定）。
// 这些断言保护的是 coding-conventions.md §7.2 的目录契约本身：仓库布局挪动（如
// Directory.Build.props 改名、fixtures 目录搬家）时在此先红，而不是在五个测试项目里
// 同时报"未找到仓库根"。样本文件选用 Providers.Tests 正在使用的真实录制样本。

#nullable enable

using System;
using System.IO;
using System.Linq;
using System.Text.Json;

using Xunit;

namespace AIQuotaBar.Core.Tests.Fixtures;

public sealed class FixturesTests
{
    private static readonly string[] ExpectedProviderDirectories =
    {
        "clash", "codex", "glm", "kimi", "minimax",
    };

    [Fact]
    public void RepositoryRoot_IsDirectoryContainingWindowsDirectoryBuildProps()
    {
        // 应然：定位约定以 windows/Directory.Build.props 为仓库根标记（实然：找不到即加载器坏）。
        Assert.True(
            File.Exists(Path.Combine(Fixtures.RepositoryRoot, "windows", "Directory.Build.props")),
            $"应然：{Fixtures.RepositoryRoot} 下存在 windows/Directory.Build.props（实然：不存在）");
    }

    [Fact]
    public void ContractsFixturesDirectory_ContainsAllProviderSubdirectories()
    {
        // 应然：五个 provider 子目录齐全（与 macOS 端共享，契约 agent 维护）。
        var missing = ExpectedProviderDirectories
            .Where(provider => !Directory.Exists(Path.Combine(Fixtures.ContractsFixturesDirectory, provider)))
            .ToArray();
        Assert.True(
            missing.Length == 0,
            $"应然：{Fixtures.ContractsFixturesDirectory} 含 {string.Join("/", ExpectedProviderDirectories)}"
                + $"（实然：缺 {string.Join(", ", missing)}）");
    }

    [Fact]
    public void Read_ReturnsRealRecordedFixtureContent()
    {
        // 应然：加载真实录制的 GLM 响应样本且为合法 JSON（实然：空/坏 JSON 即 fixtures 或加载器坏）。
        var json = Fixtures.Read("glm", "quota-limit-response-credit-single-window.json");
        Assert.False(string.IsNullOrWhiteSpace(json), "fixture 文本不应为空");
        using var document = JsonDocument.Parse(json);
        Assert.Equal(JsonValueKind.Object, document.RootElement.ValueKind);
    }

    [Fact]
    public void ReadLines_LoadsJsonlFixturePerLine()
    {
        // 应然：.jsonl 样本按行读取（实然：空文件即失败）。
        var lines = Fixtures.ReadLines("codex", "local-session-rollout.jsonl");
        Assert.True(lines.Length > 0, "local-session-rollout.jsonl 至少应有一行");
    }

    [Fact]
    public void Read_MissingFixture_ThrowsWithPathInMessage()
    {
        // 应然：缺样本时报出可定位的完整路径（供补录样本，而非静默）。
        var exception = Assert.Throws<InvalidOperationException>(
            () => Fixtures.Read("glm", "no-such-fixture.json"));
        Assert.Contains(Fixtures.ContractsFixturesDirectory, exception.Message);
        Assert.Contains("no-such-fixture.json", exception.Message);
    }
}
