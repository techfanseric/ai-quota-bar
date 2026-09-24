// Swift 来源：AIQuotaBar/Tests/GLM/GLMResetAllowanceTests.swift — final class GLMResetAllowanceTests。
// fixtures: reset-allowances-response-personal.json / reset-allowances-response-error-401.json。
// 派生样本（PERSONAL→TEAM 替换、删除 resets 数组）是对已录 fixtures 的变换，非自造响应。

using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using AIQuotaBar.Core.Contracts;
using AIQuotaBar.Providers.Glm;
using Xunit;

namespace AIQuotaBar.Providers.Tests.Glm;

public sealed class GlmResetAllowanceTests
{
    // Swift: testAvailableFlagsExpiryAndPersonalScopeAreAuthoritative
    [Fact]
    public void AvailableFlagsExpiryAndPersonalScope_AreAuthoritative()
    {
        var json = GlmFixtures.Load("reset-allowances-response-personal.json");
        var allowances = GlmResetAllowanceParser.Parse(json);

        var now = DateTimeOffset.Parse(
            "2026-09-20T00:00:00Z", CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind);
        // Swift availableFiveHour(at:)/availableWeekly(at:) 是 Core 逻辑（延后）；
        // 测试内以同语义的严格大于过滤钉住解码结果：只保留 available==true 且升序。
        Assert.Equal(1, allowances.FiveHourExpirations.Count(expiry => expiry > now));
        Assert.Equal(1, allowances.WeeklyExpirations.Count(expiry => expiry > now));
        Assert.Equal(
            new DateTimeOffset(2026, 10, 18, 17, 48, 12, TimeSpan.FromHours(8)),
            allowances.WeeklyExpirations[0]);
        // Swift: availableWeekly(at: weeklyExpirations[0]).isEmpty —— 过滤是严格大于（到期当刻即不可用）。
        Assert.Equal(0, allowances.WeeklyExpirations.Count(expiry => expiry > allowances.WeeklyExpirations[0]));
        // available == false 的 5h 条目被丢弃，仅剩 2026-10-18 18:48:45（UTC+8）。
        var onlyFiveHour = Assert.Single(allowances.FiveHourExpirations);
        Assert.Equal(new DateTimeOffset(2026, 10, 18, 18, 48, 45, TimeSpan.FromHours(8)), onlyFiveHour);

        // TEAM 作用域拒绝（fixture 文本替换派生）。
        Assert.Throws<GlmUsageException>(() => GlmResetAllowanceParser.Parse(json.Replace("PERSONAL", "TEAM")));

        // 错误信封拒绝（code 401 / success false）。
        Assert.Throws<GlmUsageException>(() =>
            GlmResetAllowanceParser.Parse(GlmFixtures.Load("reset-allowances-response-error-401.json")));

        // 缺 resets 数组拒绝。样本缺口：契约库暂无专用 fixture，这里由 personal fixture 删除字段派生
        // （TODO: 待契约 agent 补录 reset-allowances-response-missing-arrays.json 后替换）。
        var missingArrays = JsonNode.Parse(json)!;
        var data = (JsonObject)missingArrays["data"]!;
        data.Remove("fiveHourResets");
        data.Remove("weekResets");
        Assert.Throws<GlmUsageException>(() => GlmResetAllowanceParser.Parse(missingArrays.ToJsonString()));
    }

    // Swift: testRequestDoesNotSendCredentialsToUnverifiedHostsOrScopes
    // —— 只有已验证 CN 网页端点 + 个人作用域可共享凭据；2 秒有界超时；绝不携带 Cookie。
    [Fact]
    public void Request_DoesNotSendCredentials_ToUnverifiedHostsOrScopes()
    {
        static GlmCredential Credential(string url, string? organization = null) =>
            new(url, "fixture-auth", organization, null, "must-not-be-sent");

        var request = GlmResetAllowanceRequestBuilder.TryBuild(Credential(GlmCredentialParser.DefaultApiUrl));
        Assert.NotNull(request);
        Assert.Equal(
            "https://bigmodel.cn/api/biz/customer-package-reset/list?targetType=PERSONAL",
            request!.Url.ToString());
        Assert.Equal(TimeSpan.FromSeconds(2), request.Timeout);
        Assert.Equal("fixture-auth", request.Headers["Authorization"]);
        Assert.False(
            request.Headers.ContainsKey("Cookie"),
            "凭据 Cookie 不得进入 reset 请求（应然：无 Cookie 头），实然存在。");

        foreach (var url in new[]
                 {
                     GlmCredentialParser.ApiKeyUrl, // open.bigmodel.cn（API Key 端点）
                     "https://proxy.example/api/monitor/usage/quota/limit", // 未验证 host
                     "http://bigmodel.cn/api/monitor/usage/quota/limit", // 非 https
                     GlmCredentialParser.DefaultApiUrl + "?type=2", // 非默认查询参数
                 })
        {
            // 不应为该 url 构建 reset 请求（应然：null）——xUnit Assert.Null 无消息重载，说明转注释。
            Assert.Null(GlmResetAllowanceRequestBuilder.TryBuild(Credential(url)));
        }

        // 组织作用域（团队）拒绝。
        Assert.Null(GlmResetAllowanceRequestBuilder.TryBuild(
            Credential(GlmCredentialParser.DefaultApiUrl, organization: "team")));
    }

    // Swift: testGroupingPreservesAllowancesWithoutChangingQuota
    // fixture: quota-limit-response-credit-single-window.json；JSON 编解码往返保留权益且不动配额。
    [Fact]
    public void Grouping_PreservesAllowances_WithoutChangingQuota()
    {
        var quota = GlmQuotaParser.Parse(
            GlmFixtures.Load("quota-limit-response-credit-single-window.json"));
        var grouped = quota with
        {
            Models = quota.Models,
            GlmResetAllowances = new GlmResetAllowances(
                new[] { DateTimeOffset.MaxValue },
                Array.Empty<DateTimeOffset>()),
        };
        Assert.Equal(1, grouped.GlmResetAllowances!.FiveHourExpirations.Count);
        Assert.Equal(12000, grouped.Models[0].CurrentIntervalRemaining);

        var restored = JsonSerializer.Deserialize<UsageData>(
            JsonSerializer.Serialize(grouped, QuotaJson.Default), QuotaJson.Default);
        Assert.NotNull(restored);
        Assert.Equal(1, restored!.GlmResetAllowances!.FiveHourExpirations.Count);
    }
}
