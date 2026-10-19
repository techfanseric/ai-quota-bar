using AQB.App;
using AQB.Core;
using Xunit;

namespace AQB.App.Tests;

public class TrayIconRendererTests
{
    [Fact]
    public void WeeklyOnlyAccountDisplaysRemainingQuota()
    {
        var text = TrayIconRenderer.BuildDetailedText(Snapshots(Window(QuotaWindowRole.Secondary, 17)));

        Assert.StartsWith("C:83%", text);
    }

    [Fact]
    public void PrimaryWindowTakesPriorityOverWeekly()
    {
        var text = TrayIconRenderer.BuildDetailedText(Snapshots(
            Window(QuotaWindowRole.Secondary, 17), Window(QuotaWindowRole.Primary, 40)));

        Assert.StartsWith("C:60%", text);
    }

    [Fact]
    public void FailedFetchDoesNotDisplayQuotaAsCurrent()
    {
        var snapshots = Snapshots(Window(QuotaWindowRole.Secondary, 17));
        snapshots[ProviderKind.Codex] = new ProviderSnapshot
        {
            Kind = ProviderKind.Codex,
            Status = ProviderStatus.Failed,
        };

        Assert.Equal("C:--", TrayIconRenderer.BuildDetailedText(snapshots));
    }

    private static QuotaWindowSample Window(QuotaWindowRole role, double used) => new()
    {
        Role = role,
        Name = role == QuotaWindowRole.Primary ? "5h" : "Weekly",
        WindowSeconds = role == QuotaWindowRole.Primary ? 18000 : 604800,
        UsedPercent = used,
        ResetsAtUtc = DateTimeOffset.UtcNow.AddDays(2),
        CapturedAtUtc = DateTimeOffset.UtcNow,
    };

    private static Dictionary<ProviderKind, ProviderSnapshot> Snapshots(params QuotaWindowSample[] windows) => new()
    {
        [ProviderKind.Codex] = new ProviderSnapshot
        {
            Kind = ProviderKind.Codex,
            Status = ProviderStatus.Ok,
            Accounts = new[] { new ProviderAccountSnapshot { AccountKey = "test", Windows = windows } },
        },
    };
}
