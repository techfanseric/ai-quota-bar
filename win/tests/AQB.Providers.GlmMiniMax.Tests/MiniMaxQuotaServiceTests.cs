using AQB.Core;
using Xunit;

namespace AQB.Providers.GlmMiniMax.Tests;

public class MiniMaxQuotaServiceTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 17, 8, 0, 0, TimeSpan.Zero);

    private const string RemainsJson = """
        {
          "base_resp": {"status_code": 0, "status_msg": ""},
          "model_remains": [
            {
              "model_name": "MiniMax-M2",
              "start_time": 1775649600000,
              "end_time": 1775667600000,
              "remains_time": 1618725,
              "current_interval_total_count": 4500,
              "current_interval_usage_count": 3734,
              "current_interval_remaining_percent": 82.97,
              "current_weekly_total_count": 133000,
              "current_weekly_usage_count": 133000,
              "weekly_start_time": 1775599200000,
              "weekly_end_time": 1776204000000,
              "weekly_remains_time": 300000,
              "interval_boost_permille": 0,
              "weekly_boost_permille": 0
            }
          ]
        }
        """;

    private const string SubscribeJson = """
        {"current_subscribe": {
          "current_subscribe_title": "TokenPlanMax-年度会员",
          "current_subscribe_end_time_ts": 1790000000000,
          "curr_subscribe_combo_id": "c1",
          "current_subscribe_combo_type": 3,
          "current_subscribe_cycle_type": 3,
          "renewal_state": 1,
          "refundable": true}}
        """;

    private static StubHttpHandler OkHandler(string remains = RemainsJson, string subscribe = SubscribeJson)
        => new(request =>
        {
            if (request.Uri!.AbsolutePath.EndsWith("coding_plan/remains"))
            {
                return TestHttp.JsonResponse(200, remains);
            }

            return TestHttp.JsonResponse(200, subscribe);
        });

    [Fact]
    public async Task FetchSendsBearerAndParsesWindowsAndModels()
    {
        var handler = OkHandler();
        var service = new MiniMaxQuotaService(handler);

        var snapshot = await service.FetchAsync("minimax-token");

        Assert.Equal(ProviderStatus.Ok, snapshot.Status);
        Assert.Equal(ProviderKind.MiniMax, snapshot.Kind);
        Assert.Equal(2, handler.Requests.Count); // remains + optional subscription
        var request = handler.Requests[0];
        Assert.Equal(HttpMethod.Get, request.Method);
        Assert.Equal("https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains", request.Uri!.ToString());
        Assert.Equal("Bearer minimax-token", request.Header("Authorization"));

        // Remaining semantics inversion: usage_count 3734 of 4500 is REMAINING; the percent
        // field (82.97 remaining) takes precedence → used 17.03%.
        var model = Assert.Single(snapshot.Models);
        Assert.Equal("MiniMax-M2", model.ModelName);
        Assert.Equal(17.03, model.UsedPercent, 2);
        Assert.Equal(82.97, model.RemainingPercent!.Value, 2);

        var account = Assert.Single(snapshot.Accounts);
        Assert.Equal(2, account.Windows.Count);
        var interval = account.Windows[0];
        Assert.Equal("5h", interval.Name);
        Assert.Equal(QuotaWindowRole.Secondary, interval.Role);
        Assert.Equal(18000, interval.WindowSeconds);
        Assert.Equal(DateTimeOffset.FromUnixTimeMilliseconds(1775649600000), interval.StartsAtUtc);
        Assert.Equal(DateTimeOffset.FromUnixTimeMilliseconds(1775667600000), interval.ResetsAtUtc);
        var weekly = account.Windows[1];
        Assert.Equal("Weekly", weekly.Name);
        Assert.Equal(QuotaWindowRole.Primary, weekly.Role);
        Assert.Equal(604800, weekly.WindowSeconds);
        Assert.Equal(0, weekly.UsedPercent, 3); // weekly usage_count == total → nothing used

        Assert.Equal("TokenPlanMax-年度会员", snapshot.SubscribeTitle);
        Assert.Equal(
            DateTimeOffset.FromUnixTimeMilliseconds(1790000000000).UtcDateTime.ToString("yyyy-MM-dd"),
            snapshot.SubscribeEndTimeText);
    }

    [Fact]
    public async Task ExistingBearerPrefixIsKept()
    {
        var handler = OkHandler();
        var service = new MiniMaxQuotaService(handler);
        await service.FetchAsync("Bearer raw-token");
        Assert.Equal("Bearer raw-token", handler.Requests[0].Header("Authorization"));
    }

    [Fact]
    public void RemainingCountSemanticsInvertToUsed()
    {
        // No percent field: used = total - usage_count(=remaining count).
        var json = """
            {"base_resp": {"status_code": 0}, "model_remains": [
              {"model_name": "M2", "current_interval_total_count": 100, "current_interval_usage_count": 90,
               "start_time": 1775649600000, "end_time": 1775667600000}]}
            """;
        var snapshot = MiniMaxQuotaService.ParseRemains(json, null, Now);
        var model = Assert.Single(snapshot.Models);
        Assert.Equal(10, model.UsedPercent, 3);
        Assert.Equal(90, model.RemainingPercent!.Value, 3);
    }

    [Fact]
    public void PercentFieldTakesPrecedence()
    {
        var json = """
            {"base_resp": {"status_code": 0}, "model_remains": [
              {"model_name": "M2", "current_interval_total_count": 100, "current_interval_usage_count": 90,
               "current_interval_remaining_percent": 83,
               "start_time": 1775649600000, "end_time": 1775667600000}]}
            """;
        var snapshot = MiniMaxQuotaService.ParseRemains(json, null, Now);
        var model = Assert.Single(snapshot.Models);
        Assert.Equal(17, model.UsedPercent, 3);
        Assert.Equal(83, model.RemainingPercent!.Value, 3);
    }

    [Fact]
    public void WeeklyUnlimitedUsesZeroConsumption()
    {
        var json = """
            {"base_resp": {"status_code": 0}, "model_remains": [
              {"model_name": "M2", "current_interval_total_count": 100, "current_interval_usage_count": 90,
               "current_weekly_total_count": 0, "current_weekly_usage_count": 0, "current_weekly_remaining_percent": 100,
               "start_time": 1775649600000, "end_time": 1775667600000,
               "weekly_start_time": 1775599200000, "weekly_end_time": 1776204000000}]}
            """;
        var snapshot = MiniMaxQuotaService.ParseRemains(json, null, Now);
        var weekly = Assert.Single(snapshot.Accounts).Windows.Single(w => w.Name == "Weekly");
        Assert.Equal(0, weekly.UsedPercent, 3);
    }

    [Fact]
    public void RemainsTimeFillsResetWhenStartEndMissing()
    {
        var json = """
            {"base_resp": {"status_code": 0}, "model_remains": [
              {"model_name": "M2", "current_interval_total_count": 100, "current_interval_usage_count": 50,
               "remains_time": 3600000}]}
            """;
        var snapshot = MiniMaxQuotaService.ParseRemains(json, null, Now);
        var interval = Assert.Single(snapshot.Accounts).Windows.Single(w => w.Name == "5h");
        Assert.Equal(0, interval.WindowSeconds);
        Assert.Null(interval.StartsAtUtc);
        Assert.Equal(Now.AddMilliseconds(3600000), interval.ResetsAtUtc);
    }

    [Fact]
    public void NonZeroStatusCodeFailsWithStatusMessage()
    {
        var json = """{"base_resp": {"status_code": 1001, "status_msg": "invalid token"}}""";
        var snapshot = MiniMaxQuotaService.ParseRemains(json, null, Now);
        Assert.Equal(ProviderStatus.Failed, snapshot.Status);
        Assert.Equal("invalid token", snapshot.Error);
    }

    [Fact]
    public async Task NonSuccessHttpStatusFails()
    {
        var handler = new StubHttpHandler(_ => TestHttp.JsonResponse(403, "{}"));
        var service = new MiniMaxQuotaService(handler);
        var snapshot = await service.FetchAsync("t");
        Assert.Equal(ProviderStatus.Failed, snapshot.Status);
        Assert.Equal("MiniMax HTTP 403", snapshot.Error);
    }

    [Fact]
    public void ZeroOrMissingSubscribeTsHidesEndText()
    {
        var zero = """{"current_subscribe": {"current_subscribe_title": "Plan", "current_subscribe_end_time_ts": 0}}""";
        var snapshot = MiniMaxQuotaService.ParseRemains(RemainsJson, zero, Now);
        Assert.Equal("Plan", snapshot.SubscribeTitle);
        Assert.Null(snapshot.SubscribeEndTimeText);

        var none = MiniMaxQuotaService.ParseRemains(RemainsJson, null, Now);
        Assert.Null(none.SubscribeTitle);
        Assert.Null(none.SubscribeEndTimeText);
    }

    [Fact]
    public async Task SubscriptionEndpointFailureIsSilent()
    {
        var handler = new StubHttpHandler(request =>
        {
            if (request.Uri!.AbsolutePath.EndsWith("coding_plan/remains"))
            {
                return TestHttp.JsonResponse(200, RemainsJson);
            }

            return TestHttp.JsonResponse(500, "{}");
        });
        var service = new MiniMaxQuotaService(handler);

        var snapshot = await service.FetchAsync("t");

        Assert.Equal(ProviderStatus.Ok, snapshot.Status);
        Assert.Null(snapshot.SubscribeTitle);
        Assert.Null(snapshot.SubscribeEndTimeText);
    }

    [Fact]
    public void EmptyModelRowsFail()
    {
        var snapshot = MiniMaxQuotaService.ParseRemains("""{"base_resp": {"status_code": 0}, "model_remains": []}""", null, Now);
        Assert.Equal(ProviderStatus.Failed, snapshot.Status);
    }
}
