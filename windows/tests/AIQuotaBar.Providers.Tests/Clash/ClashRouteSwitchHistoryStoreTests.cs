// Swift 来源：AIQuotaBar/Tests/Clash/ClashRouteSwitchHistoryStoreTests.swift（v1.28.1）
// 持久化差异：Swift 用 UserDefaults suite；Windows 端注入临时 JSON 文件路径（逻辑断言一致）。

#nullable enable

using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using AIQuotaBar.Providers.Clash;
using Xunit;

namespace AIQuotaBar.Providers.Tests.Clash;

public sealed class ClashRouteSwitchHistoryStoreTests
{
    [Fact]
    public async Task PersistsOnlyThreeMostRecentSwitches()
    {
        var filePath = TempFilePath("clash-route-switch");
        try
        {
            var store = new ClashRouteSwitchHistoryStore(filePath);
            var start = DateTimeOffset.FromUnixTimeSeconds(1_785_307_200);

            for (var index = 0; index < 4; index++)
            {
                await store.RecordSwitchAsync(
                    fromRoute: $"Route {index}",
                    toRoute: $"Route {index + 1}",
                    switchedAt: start.AddSeconds(index));
            }

            var records = await new ClashRouteSwitchHistoryStore(filePath).LoadAsync();

            // 应然：只保留最近 3 条、新的在前（实然顺序/数量不符即失败）。
            Assert.Equal(3, records.Count);
            Assert.Equal(new[] { "Route 4", "Route 3", "Route 2" }, records.Select(record => record.ToRoute).ToArray());
            Assert.Equal(new[] { "Route 3", "Route 2", "Route 1" }, records.Select(record => record.FromRoute).ToArray());
        }
        finally
        {
            TryDeleteFile(filePath);
        }
    }

    [Fact]
    public async Task DoesNotRecordNoOpSwitch()
    {
        var filePath = TempFilePath("clash-route-switch-noop");
        try
        {
            var store = new ClashRouteSwitchHistoryStore(filePath);

            var records = await store.RecordSwitchAsync(fromRoute: "JP 01", toRoute: "JP 01");

            Assert.Empty(records);
            Assert.Empty(await store.LoadAsync());
        }
        finally
        {
            TryDeleteFile(filePath);
        }
    }

    [Fact]
    public void RouteTypeBadgesUseCompactProtocolLabels()
    {
        Assert.Equal("H2", ClashRouteTypeBadge.Text("Hysteria2"));
        Assert.Equal("VL", ClashRouteTypeBadge.Text("VLESS"));
        Assert.Equal("TLS", ClashRouteTypeBadge.Text("AnyTLS"));
        Assert.Equal("WG", ClashRouteTypeBadge.Text("WireGuard"));
        Assert.Equal("CUS", ClashRouteTypeBadge.Text("Custom Proxy"));
    }

    [Fact]
    public void RecentSwitchesUseRelativeMinutesForFirstHour()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1_785_307_200);

        Assert.Equal(
            "now",
            ClashRouteSwitchTimeFormat.Text(now.AddSeconds(-59), now, AppLanguage.English));
        Assert.Equal(
            "1m ago",
            ClashRouteSwitchTimeFormat.Text(now.AddSeconds(-60), now, AppLanguage.English));
        Assert.Equal(
            "59m ago",
            ClashRouteSwitchTimeFormat.Text(now.AddSeconds(-(59 * 60 + 59)), now, AppLanguage.English));
        Assert.Equal(
            "1 分钟前",
            ClashRouteSwitchTimeFormat.Text(now.AddSeconds(-60), now, AppLanguage.SimplifiedChinese));
    }

    private static string TempFilePath(string prefix) =>
        Path.Combine(Path.GetTempPath(), $"{prefix}-{Guid.NewGuid():N}.json");

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
