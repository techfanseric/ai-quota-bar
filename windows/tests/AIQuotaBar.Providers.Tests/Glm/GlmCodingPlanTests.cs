// Swift 来源：无（Windows 端新增）——coding-plan 余额端点（zcode.z.ai/api/v1/zcode-plan/billing/balance）
// 在 macOS Swift 端无对应实现与测试。解析测试一律从 windows/contracts/fixtures/glm/ 加载真实契约样本
// coding-plan-balance.real.json（[real-captured]，ZCode 3.14.3 Windows 客户端日志录制于 2026-09-27，
// 账号唯一 ID/logid 已脱敏，数值真实）；坏形状样本由该 fixture 的 JsonNode 派生变换构成（先例：
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

    // fixture: coding-plan-balance.real.json —— GLM-5.3-Flash 桶 total_units=300000000 /
    // remaining_units=241495318（80.498% 剩余），period 2026-09-24T12:14:55Z → 2026-09-28T01:00:00Z
    // （Unix 秒 1790252095 / 1790557200）。取样时刻注入 server_time（2026-09-26T22:29:38Z）。
    [Fact]
    public void BalanceFixture_MapsToPercentRowWithRealCounts()
    {
        var now = ParseUtc("2026-09-26T22:29:38Z");
        var usage = GlmCodingPlanParser.Parse(
            GlmFixtures.Load("coding-plan-balance.real.json"), now);

        Assert.Equal(UsageProvider.Glm, usage.Provider);
        Assert.Equal(1, usage.Total);
        Assert.Equal(1, usage.Remains); // 80% > 0 → 当前周期仍有额度

        var row = Assert.Single(usage.Models);
        Assert.Equal("GLM-5.3-Flash", row.ModelName); // 行名取 balances[].show_name（real 形状）
        // 百分比制：241495318/300000000 = 80.498% → AwayFromZero 舍入 80（舍入语义对齐 GlmQuotaParser）。
        Assert.Equal(100, row.CurrentIntervalTotal);
        Assert.Equal(80, row.CurrentIntervalRemaining);
        Assert.Equal(80, row.CurrentIntervalRemainingPercent);
        Assert.Equal("%", row.ValueSuffix);
        // 原始计数保留在明细文本，百分比换算不丢信息（应然："241495318 / 300000000 tokens"）。
        Assert.Equal("241495318 / 300000000 tokens", row.DetailText);

        // Unix 秒 → DateTimeOffset（real fixture 钉死秒级精度；应然起止见 fixture 注释）。
        Assert.Equal(ParseUtc("2026-09-24T12:14:55Z"), row.StartTime);
        Assert.Equal(ParseUtc("2026-09-28T01:00:00Z"), row.EndTime);
        // 22:29:38Z 取样 → 距 period_end 95422 秒（毫秒，向零截断）。
        Assert.Equal(95_422_000, row.RemainsTimeMilliseconds);
    }

    // plans[]（status=active）→ 订阅元数据：priority 最高的 active plan 的 name 与 ends_at。
    [Fact]
    public void ActivePlans_DriveSubscribeTitleAndEndTime()
    {
        var usage = GlmCodingPlanParser.Parse(
            GlmFixtures.Load("coding-plan-balance.real.json"));

        Assert.Equal("ZCode Weekend Build", usage.SubscribeTitle);
        Assert.Equal(ParseUtc("2026-09-28T01:00:00Z"), usage.SubscribeEndTime);
    }

    // 过期 plan 过滤：status != "active"（如 "expired"）的计划不参与订阅映射（status 是唯一权威，不用时钟推断）。
    [Fact]
    public void ExpiredPlan_IsFilteredFromSubscription()
    {
        var usage = GlmCodingPlanParser.Parse(
            Transform(root => ((JsonObject)((JsonArray)root["data"]!["plans"]!)[0]!)["status"] = "expired"));

        Assert.Null(usage.SubscribeTitle);
        Assert.Null(usage.SubscribeEndTime);
        // 订阅缺失不影响余额行。
        Assert.Equal("GLM-5.3-Flash", Assert.Single(usage.Models).ModelName);
    }

    // 多个 balance 多行：balances[] 每个余额桶一行，行序与数组一致。
    [Fact]
    public void MultipleBalances_ProduceOneRowPerBucket()
    {
        var usage = GlmCodingPlanParser.Parse(Transform(root =>
        {
            var balances = (JsonArray)root["data"]!["balances"]!;
            var second = (JsonObject)balances[0]!.DeepClone();
            second["bucket_id"] = "bucket_SECOND_BUCKET_ID";
            second["show_name"] = "GLM-5.3";
            second["total_units"] = 1000000;
            second["used_units"] = 750000;
            second["remaining_units"] = 250000;
            second["available_units"] = 250000;
            balances.Add(second);
        }));

        Assert.Equal(2, usage.Total);
        Assert.Equal(2, usage.Remains);
        Assert.Equal(new[] { "GLM-5.3-Flash", "GLM-5.3" }, usage.Models.Select(row => row.ModelName));

        Assert.Equal(80, usage.Models[0].CurrentIntervalRemaining);
        // 250000/1000000 = 25%；克隆桶共享周期窗口。
        Assert.Equal(25, usage.Models[1].CurrentIntervalRemaining);
        Assert.Equal("250000 / 1000000 tokens", usage.Models[1].DetailText);
        Assert.Equal(ParseUtc("2026-09-28T01:00:00Z"), usage.Models[1].EndTime);
    }

    // priority 更高的 active plan 赢得 SubscribeTitle；SubscribeEndTime 取 active plan 的 ends_at 最大值。
    [Fact]
    public void HigherPriorityPlan_WinsSubscribeTitle()
    {
        var usage = GlmCodingPlanParser.Parse(Transform(root => AddPlan(root, "ZCode Pro Max", 200, 1790643600)));

        Assert.Equal("ZCode Pro Max", usage.SubscribeTitle);
        Assert.Equal(ParseUtc("2026-09-29T01:00:00Z"), usage.SubscribeEndTime);
    }

    // 并列最高 priority：name 按出现顺序拼接去重（同名桶只留一份）。
    [Fact]
    public void TiedTopPriorityPlans_JoinAndDeduplicateNames()
    {
        var usage = GlmCodingPlanParser.Parse(Transform(root =>
        {
            AddPlan(root, "ZCode Weekend Build", 100, 1790252095); // 与既有 top 计划同名 → 去重
            AddPlan(root, "ZCode Backup", 100, 1790252095); // 并列 priority → 拼接
        }));

        Assert.Equal("ZCode Weekend Build · ZCode Backup", usage.SubscribeTitle);
        // ends_at 仍是全部 active plan 的最大值（新增计划的 ends_at 更早，不拉低）。
        Assert.Equal(ParseUtc("2026-09-28T01:00:00Z"), usage.SubscribeEndTime);
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
        yield return new object[]
        {
            // msg 为空串时错误信息回退为错误码文本（real 信封成功响应 msg 即为 ""）。
            Transform(root =>
            {
                root["code"] = 500;
                root["msg"] = "";
            }),
            GlmUsageErrorKind.ApiError, "code=500",
        };
        yield return new object[] { Transform(root => root.Remove("data")), GlmUsageErrorKind.InvalidResponse, "'data'" };
        yield return new object[]
        {
            Transform(root => ((JsonObject)root["data"]!).Remove("balances")), GlmUsageErrorKind.InvalidResponse, "'balances'",
        };
        yield return new object[]
        {
            Transform(root => ((JsonObject)root["data"]!)["balances"] = "not-an-array"),
            GlmUsageErrorKind.InvalidResponse, "'balances'",
        };
        yield return new object[]
        {
            // 空数组与空 limits 同罪：不得“连接成功但没有数据”（GlmQuotaParser 先例）。
            Transform(root => ((JsonObject)root["data"]!)["balances"] = new JsonArray()),
            GlmUsageErrorKind.InvalidResponse, "'balances'",
        };
        yield return new object[]
        {
            Transform(root => ((JsonArray)root["data"]!["balances"]!)[0] = 42),
            GlmUsageErrorKind.InvalidResponse, "'balances'",
        };
        yield return new object[]
        {
            Transform(root => Balance(root).Remove("show_name")), GlmUsageErrorKind.InvalidResponse, "'show_name'",
        };
        yield return new object[]
        {
            Transform(root => Balance(root).Remove("total_units")), GlmUsageErrorKind.InvalidResponse, "'total_units'",
        };
        yield return new object[]
        {
            Transform(root => Balance(root)["total_units"] = "300000000"), GlmUsageErrorKind.InvalidResponse, "'total_units'",
        };
        yield return new object[]
        {
            Transform(root => Balance(root)["total_units"] = 0), GlmUsageErrorKind.InvalidResponse, "'total_units'",
        };
        yield return new object[]
        {
            Transform(root => Balance(root)["total_units"] = -5), GlmUsageErrorKind.InvalidResponse, "'total_units'",
        };
        yield return new object[]
        {
            Transform(root => Balance(root).Remove("remaining_units")), GlmUsageErrorKind.InvalidResponse, "'remaining_units'",
        };
        yield return new object[]
        {
            Transform(root => Balance(root)["remaining_units"] = true), GlmUsageErrorKind.InvalidResponse, "'remaining_units'",
        };
        yield return new object[]
        {
            // 时间字段钉死 Unix 秒数字：ISO8601 文本不被接受（real fixture 校准结论）。
            Transform(root => Balance(root)["period_end"] = "2026-09-28T01:00:00Z"),
            GlmUsageErrorKind.InvalidResponse, "'period_end'",
        };
        yield return new object[]
        {
            // 同理，非整数的秒值（1790252095.5）拒绝。
            Transform(root => Balance(root)["period_start"] = 1790252095.5),
            GlmUsageErrorKind.InvalidResponse, "'period_start'",
        };
        yield return new object[]
        {
            Transform(root => ((JsonObject)root["data"]!)["plans"] = "oops"), GlmUsageErrorKind.InvalidResponse, "'plans'",
        };
        yield return new object[]
        {
            Transform(root => ((JsonArray)root["data"]!["plans"]!)[0] = "not-an-object"),
            GlmUsageErrorKind.InvalidResponse, "'plans'",
        };
        yield return new object[]
        {
            Transform(root => Plan(root)["priority"] = "high"), GlmUsageErrorKind.InvalidResponse, "'priority'",
        };
        yield return new object[]
        {
            Transform(root => Plan(root)["ends_at"] = "soon"), GlmUsageErrorKind.InvalidResponse, "'ends_at'",
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

    // remaining_units 越界不抛错：钳制到 [0, total_units] 再换算百分比（GlmQuotaParser 同哲学）。
    [Fact]
    public void OutOfRangeRemainingUnits_IsClampedIntoPercentScale()
    {
        var zeroed = GlmCodingPlanParser.Parse(
            Transform(root => Balance(root)["remaining_units"] = -20));
        var zeroedRow = Assert.Single(zeroed.Models);
        Assert.Equal(0, zeroedRow.CurrentIntervalRemaining);
        Assert.Equal(0, zeroed.Remains); // 0% → 当前周期不可用，应然 Remains=0。
        Assert.Equal("0 / 300000000 tokens", zeroedRow.DetailText); // 计数明细同样钳制展示

        var full = GlmCodingPlanParser.Parse(
            Transform(root => Balance(root)["remaining_units"] = 999999999));
        var fullRow = Assert.Single(full.Models);
        Assert.Equal(100, fullRow.CurrentIntervalRemaining);
        Assert.Equal("300000000 / 300000000 tokens", fullRow.DetailText);
        Assert.Equal(1, full.Remains);
    }

    // 周期时间可缺失：缺失不伪造窗口（应然 null / RemainsTimeMilliseconds=0），行本身保留。
    [Fact]
    public void MissingPeriodTimes_KeepRowWithoutFabricatedWindow()
    {
        var usage = GlmCodingPlanParser.Parse(Transform(root =>
        {
            var balance = Balance(root);
            balance.Remove("period_start");
            balance.Remove("period_end");
        }));

        var row = Assert.Single(usage.Models);
        Assert.Null(row.StartTime);
        Assert.Null(row.EndTime);
        Assert.Equal(0, row.RemainsTimeMilliseconds); // 无到期时刻即无剩余毫秒可算（对齐 Codex credits 行）
        Assert.Equal(80, row.CurrentIntervalRemaining);
    }

    // 到期时刻已过：RemainsTimeMilliseconds 钳制到 0，不出现负数。
    [Fact]
    public void PastPeriodEnd_ClampsRemainsMillisecondsToZero()
    {
        var usage = GlmCodingPlanParser.Parse(
            GlmFixtures.Load("coding-plan-balance.real.json"),
            now: ParseUtc("2026-09-29T00:00:00Z"));

        Assert.Equal(0, Assert.Single(usage.Models).RemainsTimeMilliseconds);
    }

    // 契约序列化往返：百分比行与订阅元数据经 QuotaJson.Default 编解码语义不丢
    // （先例：GlmResetAllowanceTests.Grouping）。
    [Fact]
    public void ParsedUsageData_RoundTripsThroughQuotaJson()
    {
        var usage = GlmCodingPlanParser.Parse(
            GlmFixtures.Load("coding-plan-balance.real.json"));

        var restored = JsonSerializer.Deserialize<UsageData>(
            JsonSerializer.Serialize(usage, QuotaJson.Default), QuotaJson.Default);

        Assert.NotNull(restored);
        var row = Assert.Single(restored!.Models);
        Assert.Equal("GLM-5.3-Flash", row.ModelName);
        Assert.Equal(80, row.CurrentIntervalRemaining);
        Assert.Equal(100, row.CurrentIntervalTotal);
        Assert.True(
            row.EndTime is { } end && end == ParseUtc("2026-09-28T01:00:00Z"),
            $"往返后 EndTime 应保持 2026-09-28T01:00:00Z（应然），实然 {row.EndTime}。");
        Assert.True(
            restored.SubscribeTitle == "ZCode Weekend Build",
            $"往返后 SubscribeTitle 应保持 ZCode Weekend Build（应然），实然 {restored.SubscribeTitle}。");
        Assert.True(
            restored.SubscribeEndTime is { } subscribeEnd && subscribeEnd == ParseUtc("2026-09-28T01:00:00Z"),
            $"往返后 SubscribeEndTime 应保持 2026-09-28T01:00:00Z（应然），实然 {restored.SubscribeEndTime}。");
    }

    // ---------------------------------------------------------------- client：FakeHandler 注入

    // 裸 JWT 与已带 Bearer 前缀都归一为恰好一次 Bearer（对齐 GlmUsageTests.ApiKey_UsesOpenApi 语义）；
    // 请求形状（GET、端点、头）与解析结果一并钉死。
    [Fact]
    public async Task FetchCodingPlanBalance_SendsNormalizedBearer_AndParsesBalance()
    {
        var handler = new FakeHandler(_ => Ok(GlmFixtures.Load("coding-plan-balance.real.json")));
        using var httpClient = new HttpClient(handler);
        var client = new GlmClient(httpClient);

        foreach (var jwt in new[] { "fixture-jwt", "Bearer fixture-jwt" })
        {
            var usage = await client.FetchCodingPlanBalanceAsync(jwt);

            Assert.Equal(UsageProvider.Glm, usage.Provider);
            Assert.Equal("GLM-5.3-Flash", Assert.Single(usage.Models).ModelName);
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

    /// <summary>对 real fixture 做 JsonNode 派生变换（先例：GlmResetAllowanceTests / CodexOAuthRefresherTests）。</summary>
    private static string Transform(Action<JsonObject> mutate)
    {
        var root = JsonNode.Parse(GlmFixtures.Load("coding-plan-balance.real.json")) as JsonObject
            ?? throw new InvalidOperationException("coding-plan fixture 不是 JSON 对象");
        mutate(root);
        return root.ToJsonString();
    }

    /// <summary>fixture 的首个余额桶（data.balances[0]）。</summary>
    private static JsonObject Balance(JsonObject root) =>
        (JsonObject)((JsonArray)root["data"]!["balances"]!)[0]!;

    /// <summary>fixture 的首个计划（data.plans[0]）。</summary>
    private static JsonObject Plan(JsonObject root) =>
        (JsonObject)((JsonArray)root["data"]!["plans"]!)[0]!;

    /// <summary>向 fixture 追加一个 active 计划（name/priority/ends_at 由调用方指定）。</summary>
    private static void AddPlan(JsonObject root, string name, int priority, long endsAtUnixSeconds)
    {
        var plans = (JsonArray)root["data"]!["plans"]!;
        plans.Add(new JsonObject
        {
            ["user_plan_id"] = "upl_REDENCED_ACCOUNT_ID",
            ["plan_id"] = "zcode-test-extra-plan",
            ["name"] = name,
            ["priority"] = priority,
            ["status"] = "active",
            ["starts_at"] = 1790252095,
            ["ends_at"] = endsAtUnixSeconds,
            ["entitlements"] = new JsonArray(),
        });
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
