using AQB.App;
using AQB.Core;
using Xunit;

namespace AQB.App.Tests;

public class TrayIconRendererTests
{
    [Theory]
    [InlineData(16)]
    [InlineData(32)]
    public void BothModesHaveOpaqueDarkBackingAndVisibleLightPixels(int size)
    {
        using var ring = TrayIconRenderer.RenderCompactRing(new Dictionary<ProviderKind, ProviderSnapshot>(), size);
        using var text = TrayIconRenderer.RenderTextIcon("C:100% · 3.2h", size);
        foreach (var bitmap in new[] { ring, text })
        {
            var center = bitmap.GetPixel(size / 2, size / 2);
            Assert.Equal(255, center.A);
            var lightPixels = 0;
            var darkPixels = 0;
            for (var y = 0; y < size; y++)
            for (var x = 0; x < size; x++)
            {
                var pixel = bitmap.GetPixel(x, y);
                if (pixel.A < 200) continue;
                if (pixel.GetBrightness() > 0.6f) lightPixels++;
                if (pixel.GetBrightness() < 0.25f) darkPixels++;
            }
            Assert.True(lightPixels > size);
            Assert.True(darkPixels > size);
        }
    }

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
