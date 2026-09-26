// Swift 来源：无（Windows 端新增）——coding-plan 余额端点（zcode.z.ai/api/v1/zcode-plan/billing/balance）
// 在 macOS Swift 端无对应实现与测试。解析测试一律从 windows/contracts/fixtures/glm/ 加载合成契约样本
// coding-plan-balance.synthetic.json；坏形状样本由该 fixture 的 JsonNode 派生变换构成（先例：
// GlmResetAllowanceTests 的 TEAM / 缺数组改写），非自造响应。客户端测试用 FakeHandler 注入
// （风格镜像 ClashApiClientTests——GlmClient 构造函数接受 HttpClient，无既有网络测试可循）。

using System.Globalization;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AIQuotaBar.Core.Contracts;
using AIQuotaBar.Providers.Glm;
using Xunit;

namespace AIQuotaBar.Providers.Tests.Glm;

public sealed class GlmCodingPlanTests
{
    // ---------------------------------------------------------------- parser：fixture 驱动

    // fixture: coding-plan-balance.synthetic.json —— total=120 / remaining=37、5h 周期
    // 08:00Z → 13:00Z（coding-plan 为 5 小时窗口制）。取样时刻注入 12:00Z。
    [Fact]
    public void BalanceFixture_MapsToSinglePercentCodingPlanRow()
    {
        var now = ParseUtc("2026-09-26T12:00:00Z");
        var usage = GlmCodingPlanParser.Parse(
            GlmFixtures.Load("coding-plan-balance.synthetic.json"), now);

        Assert.Equal(UsageProvider.Glm, usage.Provider);
        Assert.Equal(1, usage.Total);
        Assert.Equal(1, usage.Remains); // 31% > 0 → 当前周期仍有额度

        var row = Assert.Single(usage.Models);
        Assert.Equal("Coding Plan", row.ModelName);
        // 百分比制：37/120 = 30.83% → AwayFromZero 舍入 31（舍入语义对齐 GlmQuotaParser）。
        Assert.Equal(100, row.CurrentIntervalTotal);
        Assert.Equal(31, row.CurrentIntervalRemaining);
        Assert.Equal(31, row.CurrentIntervalRemainingPercent);
        Assert.Equal("%", row.ValueSuffix);
        // 原始计数保留在明细文本，百分比换算不丢信息（应然："37 / 120 left"）。
        Assert.Equal("37 / 120 left", row.DetailText);

        Assert.Equal(ParseUtc("2026-09-26T08:00:00Z"), row.StartTime);
        Assert.Equal(ParseUtc("2026-09-26T13:00:00Z"), row.EndTime);
        // 12:00Z 取样 → 1 小时后重置（毫秒，向零截断）。
        Assert.Equal(3_600_000, row.RemainsTimeMilliseconds);
    }

    // 契约序列化往返：百分比行经 QuotaJson.Default 编解码语义不丢（先例：GlmResetAllowanceTests.Grouping）。
    [Fact]
    public void ParsedUsageData_RoundTripsThroughQuotaJson()
    {
        var usage = GlmCodingPlanParser.Parse(
            GlmFixtures.Load("coding-plan-balance.synthetic.json"));

        var restored = JsonSerializer.Deserialize<UsageData>(
            JsonSerializer.Serialize(usage, QuotaJson.Default), QuotaJson.Default);

        Assert.NotNull(restored);
        var row = Assert.Single(restored!.Models);
        Assert.Equal("Coding Plan", row.ModelName);
        Assert.Equal(31, row.CurrentIntervalRemaining);
        Assert.Equal(100, row.CurrentIntervalTotal);
        Assert.True(
            row.EndTime is { } end && end == ParseUtc("2026-09-26T13:00:00Z"),
            $"往返后 EndTime 应保持 2026-09-26T13:00:00Z（应然），实然 {row.EndTime}。");
    }

    // ---------------------------------------------------------------- parser：坏形状（fixture 派生变换）

    // (payload, expectedKind, messageFragment) —— 错误信息必须含字段名。
    public static IEnumerable<object[]> BadShapePayloads()
    {
        yield return new object[] { Transform(root => root.Remove("code")), GlmUsageErrorKind.InvalidResponse, "'code'" };
        yield return new object[]
        {
            Transform(root =>
            {
                root["code"] = 401;
                root["msg"] = "expired";
            }),
            GlmUsageErrorKind.ApiError, "expired",
        };
        yield return new object[] { Transform(root => root.Remove("data")), GlmUsageErrorKind.InvalidResponse, "'data'" };
        yield return new object[]
        {
            Transform(root => ((JsonObject)root["data"]!).Remove("total")), GlmUsageErrorKind.InvalidResponse, "'total'",
        };
        yield return new object[]
        {
            Transform(root => ((JsonObject)root["data"]!)["total"] = "120"), GlmUsageErrorKind.InvalidResponse, "'total'",
        };
        yield return new object[]
        {
            Transform(root => ((JsonObject)root["data"]!)["total"] = 0), GlmUsageErrorKind.InvalidResponse, "'total'",
        };
        yield return new object[]
        {
            Transform(root => ((JsonObject)root["data"]!).Remove("remaining")), GlmUsageErrorKind.InvalidResponse, "'remaining'",
        };
        yield return new object[]
        {
            Transform(root => ((JsonObject)root["data"]!)["remaining"] = true), GlmUsageErrorKind.InvalidResponse, "'remaining'",
        };
        yield return new object[]
        {
            Transform(root => ((JsonObject)root["data"]!).Remove("resetTime")), GlmUsageErrorKind.InvalidResponse, "'resetTime'",
        };
        yield return new object[]
        {
            // 注意不能用 "2026-09-26 13:00:00" 这类变体当坏样本：DateTimeOffset.TryParse 与 Core 的
            // SwiftIso8601DateTimeOffsetConverter 一样是宽松读取（空格分隔 / 无偏移都接受），这里
            // 钉的是"完全不是时间文本"的拒绝路径。
            Transform(root => ((JsonObject)root["data"]!)["resetTime"] = "reset-in-5h"),
            GlmUsageErrorKind.InvalidResponse, "'resetTime'",
        };
        yield return new object[]
        {
            Transform(root => ((JsonObject)root["data"]!)["startTime"] = "not-a-time"),
            GlmUsageErrorKind.InvalidResponse, "'startTime'",
        };
        yield return new object[] { "not json at all", GlmUsageErrorKind.InvalidResponse, "JSON" };
    }

    [Theory]
    [MemberData(nameof(BadShapePayloads))]
    public void BadShape_ThrowsGlmUsageExceptionWithFieldName(
        string payload,
        GlmUsageErrorKind expectedKind,
        string messageFragment)
    {
        var error = Assert.Throws<GlmUsageException>(() => GlmCodingPlanParser.Parse(payload));

        Assert.Equal(expectedKind, error.Kind);
        Assert.Contains(messageFragment, error.Message);
    }

    // ---------------------------------------------------------------- parser：边界语义

    // remaining 越界不抛错：钳制到 [0, total] 再换算百分比（GlmQuotaParser 同哲学）。
    [Fact]
    public void OutOfRangeRemaining_IsClampedIntoPercentScale()
    {
        var zeroed = GlmCodingPlanParser.Parse(
            Transform(root => ((JsonObject)root["data"]!)["remaining"] = -20));
        var zeroedRow = Assert.Single(zeroed.Models);
        Assert.Equal(0, zeroedRow.CurrentIntervalRemaining);
        Assert.Equal(0, zeroed.Remains); // 0% → 当前周期不可用，应然 Remains=0。

        var full = GlmCodingPlanParser.Parse(
            Transform(root => ((JsonObject)root["data"]!)["remaining"] = 999));
        var fullRow = Assert.Single(full.Models);
        Assert.Equal(100, fullRow.CurrentIntervalRemaining);
        Assert.Equal("120 / 120 left", fullRow.DetailText); // 计数明细同样钳制展示
        Assert.Equal(1, full.Remains);
    }

    // startTime 可缺失：缺失不伪造窗口起点（应然 null），resetTime 仍映射 EndTime。
    [Fact]
    public void MissingStartTime_KeepsRowWithoutFabricatedWindowStart()
    {
        var usage = GlmCodingPlanParser.Parse(
            Transform(root => ((JsonObject)root["data"]!).Remove("startTime")));

        var row = Assert.Single(usage.Models);
        Assert.Null(row.StartTime);
        Assert.Equal(ParseUtc("2026-09-26T13:00:00Z"), row.EndTime);
    }

    // 重置时刻已过：RemainsTimeMilliseconds 钳制到 0，不出现负数。
    [Fact]
    public void PastResetTime_ClampsRemainsMillisecondsToZero()
    {
        var usage = GlmCodingPlanParser.Parse(
            GlmFixtures.Load("coding-plan-balance.synthetic.json"),
            now: ParseUtc("2026-09-26T14:00:00Z"));

        Assert.Equal(0, Assert.Single(usage.Models).RemainsTimeMilliseconds);
    }

    // ---------------------------------------------------------------- client：FakeHandler 注入

    // 裸 JWT 与已带 Bearer 前缀都归一为恰好一次 Bearer（对齐 GlmUsageTests.ApiKey_UsesOpenApi 语义）；
    // 请求形状（GET、端点、头）与解析结果一并钉死。
    [Fact]
    public async Task FetchCodingPlanBalance_SendsNormalizedBearer_AndParsesBalance()
    {
        var handler = new FakeHandler(_ => Ok(GlmFixtures.Load("coding-plan-balance.synthetic.json")));
        using var httpClient = new HttpClient(handler);
        var client = new GlmClient(httpClient);

        foreach (var jwt in new[] { "fixture-jwt", "Bearer fixture-jwt" })
        {
            var usage = await client.FetchCodingPlanBalanceAsync(jwt);

            Assert.Equal(UsageProvider.Glm, usage.Provider);
            Assert.Equal("Coding Plan", Assert.Single(usage.Models).ModelName);
        }

        Assert.Equal(2, handler.Requests.Count);
        foreach (var request in handler.Requests)
        {
            Assert.Equal(HttpMethod.Get, request.Method);
            Assert.Equal(
                "https://zcode.z.ai/api/v1/zcode-plan/billing/balance",
                request.RequestUri!.ToString());
            // 应然：恰好一次 Bearer 前缀 + JSON Accept 头。
            Assert.Equal("Bearer fixture-jwt", request.Headers.GetValues("Authorization").Single());
            Assert.Equal("application/json", request.Headers.GetValues("Accept").Single());
        }
    }

    // 空 JWT：NotConfigured，且不发出任何请求（应然：零请求）。
    [Fact]
    public async Task EmptyJwt_ThrowsNotConfigured_WithoutSending()
    {
        var handler = new FakeHandler(_ => Ok("{}"));
        using var httpClient = new HttpClient(handler);
        var client = new GlmClient(httpClient);

        foreach (var jwt in new[] { "", "   " })
        {
            var error = await Assert.ThrowsAsync<GlmUsageException>(
                () => client.FetchCodingPlanBalanceAsync(jwt));
            Assert.Equal(GlmUsageErrorKind.NotConfigured, error.Kind);
        }

        Assert.Equal(0, handler.Requests.Count);
    }

    // 非 2xx：ApiError，消息携带服务端错误体（GetJsonAsync 既有行为，与 FetchUsageAsync 一致）。
    [Fact]
    public async Task NonSuccessStatusCode_IsApiErrorWithBodyMessage()
    {
        var handler = new FakeHandler(_ => new HttpResponseMessage(HttpStatusCode.Unauthorized)
        {
            Content = new StringContent(
                "{\"code\":401,\"msg\":\"token expired\"}", Encoding.UTF8, "application/json"),
        });
        using var httpClient = new HttpClient(handler);
        var client = new GlmClient(httpClient);

        var error = await Assert.ThrowsAsync<GlmUsageException>(
            () => client.FetchCodingPlanBalanceAsync("fixture-jwt"));

        Assert.Equal(GlmUsageErrorKind.ApiError, error.Kind);
        Assert.Contains("token expired", error.Message);
    }

    // 传输失败 → NetworkError（SendWithTimeoutAsync 既有包装）。
    [Fact]
    public async Task TransportFailure_IsNetworkError()
    {
        var handler = new FakeHandler(_ => throw new HttpRequestException("connection refused"));
        using var httpClient = new HttpClient(handler);
        var client = new GlmClient(httpClient);

        var error = await Assert.ThrowsAsync<GlmUsageException>(
            () => client.FetchCodingPlanBalanceAsync("fixture-jwt"));

        Assert.Equal(GlmUsageErrorKind.NetworkError, error.Kind);
    }

    // ---------------------------------------------------------------- 辅助

    private static DateTimeOffset ParseUtc(string text) =>
        DateTimeOffset.Parse(text, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind)
            .ToUniversalTime();

    /// <summary>对合成 fixture 做 JsonNode 派生变换（先例：GlmResetAllowanceTests / CodexOAuthRefresherTests）。</summary>
    private static string Transform(Action<JsonObject> mutate)
    {
        var root = JsonNode.Parse(GlmFixtures.Load("coding-plan-balance.synthetic.json")) as JsonObject
            ?? throw new InvalidOperationException("coding-plan fixture 不是 JSON 对象");
        mutate(root);
        return root.ToJsonString();
    }

    private static HttpResponseMessage Ok(string json) => new(HttpStatusCode.OK)
    {
        Content = new StringContent(json, Encoding.UTF8, "application/json"),
    };

    /// <summary>记录请求并同步应答（风格镜像 ClashApiClientTests.FakeHandler；本测试类无并发，免锁）。</summary>
    private sealed class FakeHandler : HttpMessageHandler
    {
        private readonly Func<HttpRequestMessage, HttpResponseMessage> _responder;

        public FakeHandler(Func<HttpRequestMessage, HttpResponseMessage> responder) => _responder = responder;

        public List<HttpRequestMessage> Requests { get; } = new();

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            Requests.Add(request);
            return Task.FromResult(_responder(request));
        }
    }
}
