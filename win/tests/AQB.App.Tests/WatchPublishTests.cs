using System.Net;
using System.Reflection;
using System.Text;
using System.Text.Json.Nodes;
using AQB.App;
using AQB.Core;
using AQB.Settings;
using AQB.Team;
using Xunit;

namespace AQB.App.Tests;

public sealed class WatchPublishTests
{
    [Fact]
    public async Task PublishesOnlySelectedLocalAccountsAndExposesActualHttpOutcome()
    {
        var settings = AppSettings.Load(Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".json"));
        settings.CodexWatchSharingEnabled = true;
        settings.CodexWatchSharedEmails = new() { " LOCAL@example.com " };
        settings.CodexWatchWatchedEmails = new() { "remote@example.com" };
        using var vault = new CredentialVault(persisted: false);
        using var orchestrator = new QuotaOrchestrator(settings, new[] { new Adapter() });
        await orchestrator.RefreshAsync(CancellationToken.None);
        using var background = new BackgroundServices(settings, vault, orchestrator);
        var handler = new Handler();
        using var client = new CodexWatchClient("test-publisher", "https://example.com", handler);
        async Task Publish() => await (Task)typeof(BackgroundServices)
            .GetMethod("PublishWatchAsync", BindingFlags.Instance | BindingFlags.NonPublic)!
            .Invoke(background, new object[] { client, CancellationToken.None })!;

        await Publish();
        Assert.Contains("报送成功", background.State.WatchPublishStatus);
        var payload = JsonNode.Parse(handler.LastBody!)!;
        Assert.Equal("test-publisher", payload["publisher"]!.GetValue<string>());
        Assert.Single(payload["accounts"]!.AsArray());
        Assert.Equal("local@example.com", payload["accounts"]![0]!["account"]!.GetValue<string>());
        Assert.Equal(63, payload["accounts"]![0]!["windows"]![0]!["remainingPercent"]!.GetValue<int>());
        Assert.NotNull(payload["accounts"]![0]!["windows"]![0]!["startsAt"]);
        Assert.Null(payload["accounts"]![0]!["windows"]![1]!["startsAt"]);
        Assert.Null(payload["accounts"]![0]!["windows"]![2]!["startsAt"]);
        Assert.Null(payload["accounts"]![0]!["windows"]![2]!["resetsAt"]);
        Assert.DoesNotContain("remote@example.com", payload.ToJsonString());

        handler.Status = HttpStatusCode.Conflict;
        await Publish();
        Assert.Contains("报送失败", background.State.WatchPublishStatus);
        Assert.Contains("HTTP 409", background.State.WatchPublishStatus);

        handler.Status = HttpStatusCode.OK;
        settings.CodexWatchSharingEnabled = false;
        await Publish();
        Assert.Empty(JsonNode.Parse(handler.LastBody!)!["accounts"]!.AsArray());
        Assert.Contains("已撤销", background.State.WatchPublishStatus);
        Assert.Null(client.LastPublishError);
    }

    private sealed class Handler : HttpMessageHandler
    {
        public HttpStatusCode Status = HttpStatusCode.OK;
        public string? LastBody;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            if (request.Method == HttpMethod.Post) LastBody = await request.Content!.ReadAsStringAsync(token);
            return new HttpResponseMessage(Status) { Content = new StringContent("{\"accounts\":[]}", Encoding.UTF8, "application/json") };
        }
    }

    private sealed class Adapter : IProviderAdapter
    {
        public ProviderKind Kind => ProviderKind.Codex;
        public bool IsConfigured => true;
        public Task<ProviderSnapshot> FetchAsync(CancellationToken token) => Task.FromResult(new ProviderSnapshot
        {
            Kind = Kind, Status = ProviderStatus.Ok,
            Accounts = new[] { new ProviderAccountSnapshot
            {
                Label = "local@example.com", PlanTitle = "pro",
                Windows = new[] { new QuotaWindowSample { Name = "Weekly", UsedPercent = 37,
                    CapturedAtUtc = DateTimeOffset.UtcNow, ResetsAtUtc = DateTimeOffset.UtcNow.AddDays(2), WindowSeconds = 604800 },
                    new QuotaWindowSample { Name = "Unknown duration", UsedPercent = 20, ResetsAtUtc = DateTimeOffset.UtcNow.AddHours(2) },
                    new QuotaWindowSample { Name = "Unknown reset", UsedPercent = 10 } }
            }, new ProviderAccountSnapshot { Label = "unselected@example.com" } }
        });
    }
}
