using System.Drawing;
using System.Runtime.ExceptionServices;
using System.Windows.Forms;
using AQB.App;
using AQB.Core;
using AQB.Settings;
using Xunit;

namespace AQB.App.Tests;

[Collection("Windows UI")]
public sealed class ControlCenterLayoutTests
{
    [Fact]
    public void CardsStayInsideBoundsAfterRepeatedDpiChanges()
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try
            {
                var settings = AppSettings.Load(Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".json"));
                using var orchestrator = new QuotaOrchestrator(settings, Enum.GetValues<ProviderKind>().Select(k => new Adapter(k)));
                orchestrator.RefreshAsync(CancellationToken.None).GetAwaiter().GetResult();
                using var form = new ControlCenterForm(orchestrator, () => { }, () => { }, () => { }, () => new HostState { Usage = new UsageSummaryView("1M", "30M", "90%", "$2"), Route = ("Proxy", "Example", 50), DashboardRunning = true, DashboardPort = 8080 });
                form.SuppressAutoClose = true;
                form.Show();
                Application.DoEvents();
                foreach (var dpi in new[] { 96, 120, 144, 168, 192, 240, 96, 192, 120 })
                {
                    form.ApplyLayoutDpi(dpi);
                    form.PerformLayout();
                    if (Environment.GetEnvironmentVariable("AQB_LAYOUT_CAPTURE_DIR") is { Length: > 0 } captureDir)
                    {
                        Directory.CreateDirectory(captureDir);
                        using var bitmap = new Bitmap(form.Width, form.Height);
                        form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, form.Size));
                        bitmap.Save(Path.Combine(captureDir, $"layout-{dpi}.png"));
                    }
                    Assert.Equal((int)Math.Round(360 * dpi / 96f), form.ClientSize.Width);
                    var cards = Descendants(form).OfType<CardPanel>().ToArray();
                    Assert.NotEmpty(cards);
                    foreach (var card in cards)
                    {
                        foreach (Control child in card.Controls)
                        {
                            Assert.True(child.Left >= 0 && child.Right <= card.ClientSize.Width,
                                $"DPI {dpi}: '{child.Text}' x={child.Left}..{child.Right}, card={card.Width}");
                            Assert.True(child.Top >= 0 && child.Bottom <= card.ClientSize.Height,
                                $"DPI {dpi}: '{child.Text}' y={child.Top}..{child.Bottom}, card={card.Height}");
                        }
                        var labels = card.Controls.OfType<Label>().ToArray();
                        for (var i = 0; i < labels.Length; i++)
                        for (var j = i + 1; j < labels.Length; j++)
                        {
                            var overlap = Rectangle.Intersect(labels[i].Bounds, labels[j].Bounds);
                            Assert.True(overlap.Width <= 1 || overlap.Height <= 1,
                                $"DPI {dpi} device={form.DeviceDpi} font={labels[i].Font.SizeInPoints} height={labels[i].Height}: overlapping '{labels[i].Text}' / '{labels[j].Text}': {overlap}");
                        }
                    }
                }
            }
            catch (Exception ex) { failure = ex; }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        Assert.True(thread.Join(TimeSpan.FromSeconds(30)), "Layout timed out");
        if (failure is not null) ExceptionDispatchInfo.Capture(failure).Throw();
    }

    private static IEnumerable<Control> Descendants(Control parent)
    {
        foreach (Control child in parent.Controls)
        {
            yield return child;
            foreach (var nested in Descendants(child)) yield return nested;
        }
    }

    private sealed class Adapter(ProviderKind kind) : IProviderAdapter
    {
        public ProviderKind Kind => kind;
        public bool IsConfigured => true;
        public Task<ProviderSnapshot> FetchAsync(CancellationToken token)
        {
            var now = DateTimeOffset.UtcNow;
            return Task.FromResult(new ProviderSnapshot
            {
                Kind = Kind, Status = ProviderStatus.Ok, LastUpdatedUtc = now,
                Accounts = new[] { new ProviderAccountSnapshot
                {
                    Label = "a-very-long-account-name-for-layout@example.com", PlanTitle = "Pro",
                    Windows = new[] {
                        new QuotaWindowSample { Name = "5h", UsedPercent = 35, CapturedAtUtc = now, ResetsAtUtc = now.AddHours(2), WindowSeconds = 18000 },
                        new QuotaWindowSample { Name = "Weekly", UsedPercent = 20, CapturedAtUtc = now, ResetsAtUtc = now.AddDays(2), WindowSeconds = 604800 }
                    }
                } }
            });
        }
    }
}
