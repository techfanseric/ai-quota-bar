// Swift 来源：无（Windows 端新增；对应 AIQuotaBar/Tests 各测试里的 fixture 加载）。
// TODO(去重)：与 AIQuotaBar.Core.Tests 的公共 fixtures 加载辅助（契约 agent 提供）合并为
// 跨测试项目复用的实现；当前按任务约定在本目录内先各自实现一份。

#nullable enable

using System;
using System.IO;
using System.Text.Json.Nodes;

namespace AIQuotaBar.Providers.Tests.Codex;

/// <summary>
/// codex fixtures 加载辅助：从 AppContext.BaseDirectory 逐级向上找仓库根（以
/// windows/Directory.Build.props 存在为标记），再拼 windows/contracts/fixtures/codex/。
/// </summary>
internal static class CodexFixtures
{
    private static readonly Lazy<string> LazyDirectory = new(FindFixturesDirectory);

    public static string Directory => LazyDirectory.Value;

    public static string Read(string fileName) => File.ReadAllText(Path.Combine(Directory, fileName));

    public static string[] ReadLines(string fileName) => File.ReadAllLines(Path.Combine(Directory, fileName));

    /// <summary>
    /// fixture 派生变换：解析为 JsonObject、原地修改后重新序列化。用于覆盖 fixtures 未单独
    /// 落盘的畸形/边界变体（如 camelCase 键、负数 available_count），不引入手写响应 JSON。
    /// </summary>
    public static string Transform(string fileName, Action<JsonObject> mutate)
    {
        var root = JsonNode.Parse(Read(fileName)) as JsonObject
            ?? throw new InvalidOperationException($"Fixture {fileName} is not a JSON object.");
        mutate(root);
        return root.ToJsonString();
    }

    private static string FindFixturesDirectory()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null &&
            !File.Exists(Path.Combine(directory.FullName, "windows", "Directory.Build.props")))
        {
            directory = directory.Parent;
        }

        if (directory is null)
        {
            throw new InvalidOperationException(
                "未找到仓库根（向上查找 windows/Directory.Build.props 失败），无法定位 codex fixtures。");
        }

        var fixtures = Path.Combine(directory.FullName, "windows", "contracts", "fixtures", "codex");
        if (!System.IO.Directory.Exists(fixtures))
        {
            throw new InvalidOperationException($"未找到 fixtures 目录：{fixtures}");
        }

        return fixtures;
    }
}
