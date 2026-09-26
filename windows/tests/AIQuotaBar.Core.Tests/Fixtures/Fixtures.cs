// Swift 来源：无（Windows 测试辅助——契约 fixtures 公共加载器）。
// 这是编码规范 §7.2 指定的"公共加载辅助类"：windows/contracts/fixtures/ 样本的唯一入口，
// 定位约定为从 AppContext.BaseDirectory 逐级向上查找仓库根（以 windows/Directory.Build.props
// 存在为标记），再拼接 windows/contracts/fixtures/<provider>/<场景>.json。
//
// 去重路线（第一步落地）：AIQuotaBar.Providers.Tests 目前有四份同构实现
//（Clash/Fixtures.cs、Codex/Fixtures/CodexFixtures.cs、Glm/GlmFixtures.cs、
// Minimax/MinimaxFixtures.cs，各自带 TODO(去重) 注释指向本类）。合并时其他测试项目以
// <Compile Include="..\AIQuotaBar.Core.Tests\Fixtures\Fixtures.cs" Link="Fixtures\Fixtures.cs" />
// 链接本文件后删除各自的本地实现（internal 可见性按链接文件同级编译即可）。
// 本类的 API 是四份现有实现的并集（Read / ReadLines / Transform / 目录定位），保证
// 后续替换是纯删除、无缺口。

#nullable enable

using System;
using System.IO;
using System.Text.Json.Nodes;

namespace AIQuotaBar.Core.Tests.Fixtures;

/// <summary>
/// windows/contracts/fixtures/ 契约样本公共加载器。测试内禁止手写/内联 API 响应 JSON，
/// 解析测试一律经由本类加载真实录制样本（coding-conventions.md §7.2）。
/// </summary>
public static class Fixtures
{
    private static readonly Lazy<string> LazyRepositoryRoot = new(FindRepositoryRoot);

    /// <summary>仓库根目录（向上查找命中 windows/Directory.Build.props 的目录，进程内缓存）。</summary>
    public static string RepositoryRoot => LazyRepositoryRoot.Value;

    /// <summary>fixtures 根目录：windows/contracts/fixtures/。</summary>
    public static string ContractsFixturesDirectory =>
        Path.Combine(RepositoryRoot, "windows", "contracts", "fixtures");

    /// <summary>指定 provider 的 fixtures 目录（如 …/fixtures/glm），目录不存在即抛错。</summary>
    public static string ProviderDirectory(string provider)
    {
        var directory = Path.Combine(ContractsFixturesDirectory, provider);
        if (!Directory.Exists(directory))
        {
            throw new InvalidOperationException($"fixtures 目录不存在：{directory}（provider={provider}）");
        }

        return directory;
    }

    /// <summary>读取指定 provider 的 fixture 文本（fileName 相对该 provider 目录）。</summary>
    public static string Read(string provider, string fileName)
    {
        var path = Path.Combine(ContractsFixturesDirectory, provider, fileName);
        if (!File.Exists(path))
        {
            throw new InvalidOperationException($"fixture 不存在：{path}（provider={provider}，file={fileName}）");
        }

        return File.ReadAllText(path);
    }

    /// <summary>按行读取 fixture（.jsonl / CLI 文本输出类样本）。</summary>
    public static string[] ReadLines(string provider, string fileName) =>
        File.ReadAllLines(Path.Combine(ContractsFixturesDirectory, provider, fileName));

    /// <summary>
    /// fixture 派生变换：解析为 JsonObject、原地修改后重新序列化。用于覆盖 fixtures 未单独
    /// 落盘的畸形/边界变体（如 camelCase 键、负数字段），不引入手写响应 JSON。
    /// </summary>
    public static string Transform(string provider, string fileName, Action<JsonObject> mutate)
    {
        var root = JsonNode.Parse(Read(provider, fileName)) as JsonObject
            ?? throw new InvalidOperationException($"Fixture {fileName} is not a JSON object.");
        mutate(root);
        return root.ToJsonString();
    }

    private static string FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null
            && !File.Exists(Path.Combine(directory.FullName, "windows", "Directory.Build.props")))
        {
            directory = directory.Parent;
        }

        return directory?.FullName
            ?? throw new InvalidOperationException("未找到仓库根（向上查找 windows/Directory.Build.props 失败）。");
    }
}
