// Swift 来源：AIQuotaBar/Tests/GLM/GLMUsageTests.swift — final class GLMUsageTests（解析与凭据部分）。
// 断言只覆盖 W1-C 范围（解析器 + 凭据）；testMenuBarGLMFollowsSelectedWindows...（UsageViewModel /
// UserDefaults / pace 计算）属 Core 计算属性与 App 层任务，暂缓（见移植映射表）。
// API 响应一律从 windows/contracts/fixtures/glm/ 加载；凭据输入文本按 Swift 测试原样输入
// （curl 命令 / API key 是被测输入而非 API 响应，不受 fixtures 禁令约束）。

using AIQuotaBar.Core.Contracts;
using AIQuotaBar.Providers.Glm;
using Xunit;

namespace AIQuotaBar.Providers.Tests.Glm;

public sealed class GlmUsageTests
{
    // Swift: testCurrentCreditResponseKeepsWindowsDistinctAndUsesServerRemaining
    // fixture: quota-limit-response-credit-windows-observed.json（2026-09-11 个人用量页实测结构，
    // 服务端独立取整 currentValue 与 remaining）。
    [Fact]
    public void CurrentCreditResponse_KeepsWindowsDistinct_AndUsesServerRemaining()
    {
        var usage = GlmQuotaParser.Parse(
            GlmFixtures.Load("quota-limit-response-credit-windows-observed.json"));

        Assert.Equal(UsageProvider.Glm, usage.Provider);
        Assert.Equal("lite", usage.SubscribeTitle);
        Assert.Equal(
            new[] { "GLM Credits (5h)", "GLM Credits (weekly)" },
            usage.Models.Select(model => model.ModelName).ToArray());
        // Swift: Set(result.models.map(\.id)).count == 2（独立 ID 才有独立历史与菜单栏选择）。
        Assert.Equal(2, usage.Models
            .Select(model => QuotaIdentity.DisplayId(model.Provider, model.AccountName, model.ModelName))
            .Distinct()
            .Count());
        Assert.Equal(new[] { 2000, 9485 }, usage.Models.Select(model => model.CurrentIntervalRemaining).ToArray());
        Assert.Equal(new[] { 2000, 10000 }, usage.Models.Select(model => model.CurrentIntervalTotal).ToArray());

        // 5h 窗口无 nextResetTime：不得伪造周期起止时间（startTime/endTime 均为 null）。
        // Swift 后续的 isShortCurrentInterval / quotaChartWindow(now:) 断言是 Core 窗口分类（延后），
        // 此处钉住其判据来源：模型名含 "5h" 且无重置元数据。
        Assert.Null(usage.Models[0].EndTime);
        Assert.Null(usage.Models[0].StartTime);
        Assert.True(
            usage.Models[0].ModelName.Contains("5h", StringComparison.Ordinal),
            $"5h 窗口模型名应含 \"5h\"（应然）, 实然 {usage.Models[0].ModelName}");

        // weekly：endTime = 毫秒时间戳 1789647732997（Swift 断言 epoch 1789647732.997 ±0.001），
        // 周窗口起点 = 重置时间 - 7 天（Swift: endTime - startTime == 7 * 24 * 3600）。
        // Nullable 值类型的 "!" 不解包（仍是 DateTimeOffset?），须用模式匹配先确认非空再取毫秒。
        var weekly = usage.Models[1];
        var expectedReset = DateTimeOffset.FromUnixTimeMilliseconds(1789647732997);
        Assert.True(
            weekly.EndTime is { } weeklyEnd
                && Math.Abs(weeklyEnd.ToUnixTimeMilliseconds() - expectedReset.ToUnixTimeMilliseconds()) <= 1,
            $"weekly endTime 应为 {expectedReset}（应然），实然 {weekly.EndTime}。");
        Assert.Equal(TimeSpan.FromDays(7), weekly.EndTime - weekly.StartTime);
    }

    // Swift: testLegacyPercentageOnlyAndMonthlyMCP
    // fixture: quota-limit-response-legacy-tokens-time.json（旧版 TOKENS_LIMIT 字符串百分比 + TIME_LIMIT 字符串计数）。
    [Fact]
    public void LegacyPercentageOnly_AndMonthlyMcp()
    {
        var reset = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
        var usage = GlmQuotaParser.Parse(
            GlmFixtures.Load("quota-limit-response-legacy-tokens-time.json"),
            subscriptionResetTime: reset);

        // TOKENS_LIMIT：字符串百分比 "12.5" → 已用 12.5 舍入 13，剩余 87%（percent 模式，值后缀 %）。
        Assert.Equal(87, usage.Models[0].CurrentIntervalRemaining);
        Assert.Equal("%", usage.Models[0].ValueSuffix);
        // 缺周期字段的 TOKENS_LIMIT 按旧版 5h 窗口处理（docs/glm-api-field-mapping.md:59）。
        Assert.Equal(reset - TimeSpan.FromHours(5), usage.Models[0].StartTime);

        // TIME_LIMIT：字符串计数 usage=1000 / currentValue=25 → 剩余 975；endTime 取订阅续期兜底。
        Assert.Equal(975, usage.Models[1].CurrentIntervalRemaining);
        Assert.Equal(reset, usage.Models[1].EndTime);
        Assert.Null(usage.Models[1].StartTime);
    }

    // Swift: testInvalidAndEmptyQuotaDoesNotReportConnectionSuccess
    // fixtures: error-401 / empty-limits / credit-missing-fields —— 解码必须失败。
    public static IEnumerable<object[]> InvalidPayloads()
    {
        yield return new object[] { "quota-limit-response-error-401.json", true };
        yield return new object[] { "quota-limit-response-empty-limits.json", false };
        yield return new object[] { "quota-limit-response-credit-missing-fields.json", false };
    }

    [Theory]
    [MemberData(nameof(InvalidPayloads))]
    public void InvalidAndEmptyQuota_DoesNotReportConnectionSuccess(string fixtureName, bool isApiError)
    {
        var json = GlmFixtures.Load(fixtureName);

        var error = Assert.Throws<GlmUsageException>(() => GlmQuotaParser.Parse(json));

        if (isApiError)
        {
            // 401 会话过期：错误体带 msg，不得报告连接成功。
            Assert.Equal(GlmUsageErrorKind.ApiError, error.Kind);
            Assert.Equal("expired", error.Message);
        }
        else
        {
            // 空 limits / 条目缺数值字段：invalidResponse。
            Assert.Equal(GlmUsageErrorKind.InvalidResponse, error.Kind);
        }
    }

    // Swift: testOutOfRangeRemainingIsClamped —— remaining:-20 / currentValue:120 → 剩余钳制到 0，不抛错。
    [Fact]
    public void OutOfRangeRemaining_IsClamped()
    {
        var usage = GlmQuotaParser.Parse(
            GlmFixtures.Load("quota-limit-response-out-of-range.json"));

        var model = Assert.Single(usage.Models);
        Assert.Equal(0, model.CurrentIntervalRemaining);
        Assert.Equal(100, model.CurrentIntervalTotal);
    }

    // Swift: testAPIKeyUsesOpenAPIAndBearerExactlyOnce —— 裸 key 与已带 Bearer 前缀都归一为恰好一次 Bearer。
    [Fact]
    public void ApiKey_UsesOpenApi_AndBearerExactlyOnce()
    {
        foreach (var input in new[] { "test-api-key", "Bearer test-api-key" })
        {
            var credential = GlmCredentialParser.Parse(input);
            Assert.Equal("https://open.bigmodel.cn/api/monitor/usage/quota/limit", credential.ApiUrl);
            Assert.Equal("Bearer test-api-key", credential.Authorization);

            var restored = GlmCredentialParser.Parse(credential.StorageString);
            Assert.Equal(credential.ApiUrl, restored.ApiUrl);
            Assert.Equal(credential.Authorization, restored.Authorization);
        }
    }

    // Swift: testWebCurlPreservesAuthenticationAndLegacyStoredCredential（curl 输入串取自 Swift 测试:119）。
    [Fact]
    public void WebCurl_PreservesAuthentication_AndLegacyStoredCredential()
    {
        var curl =
            "curl 'https://bigmodel.cn/api/monitor/usage/quota/limit' "
            + "-H 'authorization: web-session' -H 'bigmodel-organization: org' "
            + "-H 'bigmodel-project: project' -b 'session=value'";
        var credential = GlmCredentialParser.Parse(curl);
        Assert.Equal(GlmCredentialParser.DefaultApiUrl, credential.ApiUrl);
        Assert.Equal("web-session", credential.Authorization);
        Assert.Equal("org", credential.Organization);
        Assert.Equal("project", credential.Project);
        Assert.Equal("session=value", credential.Cookie);

        // 旧 JSON 存储串往返：头表逐键一致（Swift: restored.headers == credential.headers）。
        var restored = GlmCredentialParser.Parse(credential.StorageString);
        Assert.Equal(credential.Headers.Count, restored.Headers.Count);
        Assert.Equal("web-session", restored.Headers["authorization"]);
        Assert.Equal("org", restored.Headers["bigmodel-organization"]);
        Assert.Equal("project", restored.Headers["bigmodel-project"]);
        Assert.Equal("web-session", restored.Authorization);

        // 无授权头的 curl 必须拒绝。
        Assert.Throws<GlmUsageException>(() =>
            GlmCredentialParser.Parse("curl 'https://bigmodel.cn/api/monitor/usage/quota/limit'"));
    }

    // Swift: testEditableCredentialRoundTripPreservesWebContext（含引号转义的 token / cookie 往返）。
    [Fact]
    public void EditableCredential_RoundTrip_PreservesWebContext()
    {
        var web = new GlmCredential(
            GlmCredentialParser.DefaultApiUrl,
            "test'web-token",
            "org",
            "project",
            "session=a'b",
            new Dictionary<string, string> { ["accept"] = "application/json" });
        var parsed = GlmCredentialParser.Parse(web.EditableString);
        Assert.Equal(web.Authorization, parsed.Authorization);
        Assert.Equal(web.Cookie, parsed.Cookie);
        Assert.Equal(web.Organization, parsed.Organization);
        Assert.Equal(web.Project, parsed.Project);
        Assert.Equal("application/json", parsed.Headers["accept"]);

        // 纯 API Key 凭据的可编辑串就是裸 token。
        Assert.Equal("test-key", GlmCredentialParser.Parse("test-key").EditableString);
    }

    // Swift: testProviderIsAvailableForConfigurationAndDiscovery（部分移植）。
    // usesCurlCredential / keychainAccount 是展示与平台关注点，按 ProviderIdentity.cs 头注延后到 Platform 层。
    [Fact]
    public void ProviderIsAvailable_ForConfigurationAndDiscovery()
    {
        Assert.True(
            Array.IndexOf(UsageProviders.All, UsageProvider.Glm) >= 0,
            "UsageProvider.allCases 应包含 glm（应然），实然未包含。");
    }
}
