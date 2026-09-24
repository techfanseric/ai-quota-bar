// 来源：无 Swift 对应（Windows 测试辅助）。
// 定位约定见 windows/docs/coding-conventions.md §7.2：从 AppContext.BaseDirectory 逐级向上找仓库根
// （以 windows/Directory.Build.props 存在为标记），再拼 windows/contracts/fixtures/minimax/。
// TODO(W1): 契约 agent 在 AIQuotaBar.Core.Tests/Fixtures/ 提供公共加载辅助后，与 Glm 目录的同名
// 辅助一并去重（当前 Providers.Tests 根目录不属于本任务的可写范围，先按目录内小型辅助落地）。

namespace AIQuotaBar.Providers.Tests.Minimax;

/// <summary>MiniMax 契约 fixtures 加载器（windows/contracts/fixtures/minimax/）。</summary>
internal static class MinimaxFixtures
{
    public static string Load(string fileName)
    {
        var repositoryRoot = FindRepositoryRoot();
        var path = Path.Combine(repositoryRoot, "windows", "contracts", "fixtures", "minimax", fileName);
        if (!File.Exists(path))
        {
            throw new InvalidOperationException($"MiniMax fixture 不存在：{path}");
        }
        return File.ReadAllText(path);
    }

    private static string FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null
            && !File.Exists(Path.Combine(directory.FullName, "windows", "Directory.Build.props")))
        {
            directory = directory.Parent!;
        }
        return directory?.FullName
            ?? throw new InvalidOperationException("未找到仓库根（向上查找 windows/Directory.Build.props 失败）。");
    }
}
