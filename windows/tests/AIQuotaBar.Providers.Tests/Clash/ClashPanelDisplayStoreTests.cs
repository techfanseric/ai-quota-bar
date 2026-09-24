// Swift 来源：AIQuotaBar/Tests/Clash/ClashPanelDisplayStoreTests.swift（v1.28.1）
// 暂缓项：testPanelHeightCollapsesAndRestores（ClashPopoverLayout 属 Views/UI 层，见移植报告）。
// 持久化差异：Swift 用 UserDefaults suite；Windows 端注入临时 JSON 文件路径（逻辑断言一致）。

#nullable enable

using System;
using System.IO;
using AIQuotaBar.Providers.Clash;
using Xunit;

namespace AIQuotaBar.Providers.Tests.Clash;

public sealed class ClashPanelDisplayStoreTests
{
    [Fact]
    public void TogglePersistsAndRoundTripsThroughDefaults()
    {
        var filePath = TempFilePath();
        try
        {
            var store = new ClashPanelDisplayStore(filePath);
            Assert.False(store.IsRoutesCollapsed);
            Assert.False(store.IsConnectionsCollapsed);

            store.Toggle(ClashPanelSection.Routes);

            Assert.True(store.IsRoutesCollapsed, "折叠 routes 后应只收起 routes 分区");
            Assert.False(store.IsConnectionsCollapsed);

            // 重新加载（等价 Swift 端新建 store 读同一 defaults）。
            var reloaded = new ClashPanelDisplayStore(filePath);
            Assert.True(reloaded.IsRoutesCollapsed, "折叠状态应持久化并在重载后保持");
            Assert.False(reloaded.IsConnectionsCollapsed);
        }
        finally
        {
            TryDeleteFile(filePath);
        }
    }

    [Fact]
    public void FollowEnabledAlignsBothSectionsToCodexPresence()
    {
        var filePath = TempFilePath();
        try
        {
            var store = new ClashPanelDisplayStore(filePath);

            store.AlignWithCodexPresence(isRunning: true, followRunningAppsEnabled: true);
            Assert.False(store.IsRoutesCollapsed);
            Assert.False(store.IsConnectionsCollapsed);

            store.AlignWithCodexPresence(isRunning: false, followRunningAppsEnabled: true);
            Assert.True(store.IsRoutesCollapsed, "Codex 未运行时两段都应收起");
            Assert.True(store.IsConnectionsCollapsed, "Codex 未运行时两段都应收起");
        }
        finally
        {
            TryDeleteFile(filePath);
        }
    }

    [Fact]
    public void AlignIgnoredWhenFollowDisabled()
    {
        var filePath = TempFilePath();
        try
        {
            var store = new ClashPanelDisplayStore(filePath);
            store.SetCollapsed(true, ClashPanelSection.Routes);

            store.AlignWithCodexPresence(isRunning: true, followRunningAppsEnabled: false);

            Assert.True(store.IsRoutesCollapsed, "跟随关闭时对齐不应改动手动状态");
            Assert.False(store.IsConnectionsCollapsed);
        }
        finally
        {
            TryDeleteFile(filePath);
        }
    }

    [Fact]
    public void ManualExpandHoldsUntilNextPresenceAlignment()
    {
        var filePath = TempFilePath();
        try
        {
            var store = new ClashPanelDisplayStore(filePath);
            store.AlignWithCodexPresence(isRunning: false, followRunningAppsEnabled: true);

            store.SetCollapsed(false, ClashPanelSection.Routes);
            Assert.False(store.IsRoutesCollapsed);

            // 下一次 presence 对齐（最后操作生效），手动展开被重新收起——与左键菜单供应商区语义一致。
            store.AlignWithCodexPresence(isRunning: false, followRunningAppsEnabled: true);
            Assert.True(store.IsRoutesCollapsed);
            Assert.True(store.IsConnectionsCollapsed);
        }
        finally
        {
            TryDeleteFile(filePath);
        }
    }

    // ---------------------------------------------------------------- helpers

    private static string TempFilePath() =>
        Path.Combine(Path.GetTempPath(), $"clash-panel-display-{Guid.NewGuid():N}.json");

    private static void TryDeleteFile(string filePath)
    {
        try
        {
            if (File.Exists(filePath))
            {
                File.Delete(filePath);
            }
        }
        catch (IOException)
        {
            // 清理失败不影响断言。
        }
    }
}
