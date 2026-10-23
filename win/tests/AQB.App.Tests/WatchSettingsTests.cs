using System.Runtime.ExceptionServices;
using System.Windows.Forms;
using AQB.App;
using AQB.Settings;
using Xunit;

namespace AQB.App.Tests;

public sealed class WatchSettingsTests
{
    [Fact]
    public void WatchValidatesNormalizesPersistsAndRemovesWithoutEnablingSharing()
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            var path = Path.Combine(Path.GetTempPath(), "aqb-watch-" + Guid.NewGuid() + ".json");
            try
            {
                var settings = AppSettings.Load(path);
                using var vault = new CredentialVault(persisted: false);
                using var orchestrator = new QuotaOrchestrator(settings, Array.Empty<IProviderAdapter>());
                var refreshes = 0;
                using var form = new SettingsForm(settings, vault, () => { },
                    () => new HostState(), () => refreshes++, orchestrator);
                var providers = Descendants(form).OfType<TabPage>().Single(p => p.Text == "Providers");
                var input = Descendants(providers).OfType<TextBox>().Single(t => t.PlaceholderText == "对方 Codex 账号的邮箱");
                var add = Descendants(providers).OfType<Button>().Single(b => b.Text == "添加关注");
                // Invoke the click event without opening a visible settings window.
                void Click(Button button) => typeof(Button).GetMethod("OnClick",
                    System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!
                    .Invoke(button, new object[] { EventArgs.Empty });
                input.Text = "invalid";
                Click(add);
                Assert.Empty(settings.CodexWatchWatchedEmails);
                Assert.Contains(Descendants(providers).OfType<Label>(), l => l.Text == "请输入完整的邮箱地址。");
                input.Text = " Person@Example.com ";
                Click(add);
                Assert.Equal(new[] { "person@example.com" }, AppSettings.Load(path).CodexWatchWatchedEmails);
                Assert.Equal(1, refreshes);
                Assert.False(settings.CodexWatchSharingEnabled);
                input.Text = "PERSON@example.com";
                Click(add);
                Assert.Single(settings.CodexWatchWatchedEmails);
                Assert.Equal(1, refreshes);
                var remove = Descendants(providers).OfType<Button>().Single(b => b.Text == "移除关注");
                Click(remove);
                Assert.Empty(AppSettings.Load(path).CodexWatchWatchedEmails);
                Assert.Equal(2, refreshes);
            }
            catch (Exception ex) { failure = ex; }
            finally { if (File.Exists(path)) File.Delete(path); }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        Assert.True(thread.Join(TimeSpan.FromSeconds(20)), "Settings interaction timed out");
        if (failure is not null) ExceptionDispatchInfo.Capture(failure).Throw();
    }

    private static IEnumerable<Control> Descendants(Control parent)
    {
        foreach (Control child in parent.Controls)
        {
            yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }
}
