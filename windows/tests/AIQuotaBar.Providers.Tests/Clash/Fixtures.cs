// Swift 来源：无（Windows 端新增测试辅助——fixtures 定位与读取）。
// TODO(去重)：编码规范 §7.2 约定由契约 agent 在 AIQuotaBar.Core.Tests 提供 Fixtures/ 公共加载类；
// 该类落地后应与本实现合并（先行在本目录实现，保证 W1-B 可独立落地；与其他测试目录的
// 重复实现是有意的过渡态）。
//
// fixtures 定位：从 AppContext.BaseDirectory 逐级向上查找仓库根
//（以 windows/Directory.Build.props 存在为标记），再拼接 windows/contracts/fixtures/。

#nullable enable

using System;
using System.IO;

namespace AIQuotaBar.Providers.Tests.Clash;

internal static class Fixtures
{
    public static string ReadClashFixture(string fileName) =>
        File.ReadAllText(Path.Combine(LocateContractsFixtures(), "clash", fileName));

    public static string LocateContractsFixtures()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "Directory.Build.props")))
            {
                return Path.Combine(directory.FullName, "contracts", "fixtures");
            }

            directory = directory.Parent;
        }

        throw new InvalidOperationException(
            "未找到仓库根 windows/Directory.Build.props，无法定位 contracts/fixtures 目录。");
    }
}
