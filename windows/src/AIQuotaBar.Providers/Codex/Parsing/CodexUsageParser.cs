// Swift 来源（解析分支逐条镜像，契约样本：windows/contracts/fixtures/codex/ 全部 usage/whoami/
//   rate-limit-reset-credits / workspace-remaining-balance / usage-snapshot 样本）：
//   - CodexOAuthUsageFetcher.swift（CodexUsageResponse 解码、CodexWorkspaceRemainingBalanceResponse、
//     RateLimitResetCreditsResponse、whoami 解码、resolve*URL 的路径拼接）
//   - CodexReconciledState.swift（fromOAuth/fromPAT → 窗口归一 + 身份解析）
//   - CodexProviderDescriptor.swift（CodexOAuthFetchStrategy.mapCredits / makeResult 的
//     dataConfidence 与部分结果语义）
// 对应测试：AIQuotaBar.Providers.Tests/Codex/CodexUsageParserTests.cs
//
// 明确不做（后续阶段）：HTTP 抓取本身（fetchUsage/fetchWhoami 等网络环节）、工作区余额与
// spend-controls 的富集编排、CLI/web 数据源、UsageFormatter.resetDescription 本地化文案生成。

#nullable enable

using System;
using System.Collections.Generic;
using System.Text.Json;
using AIQuotaBar.Core.Contracts;
using AIQuotaBar.Providers.Codex.Credentials;

namespace AIQuotaBar.Providers.Codex.Parsing;

/// <summary>
/// Codex 各端点响应 → 中间表示 / <see cref="Contracts.UsageData"/> 的纯解析层。
/// 全部方法无 IO、无时钟依赖（时间显式传入），网络与刷新编排属后续阶段。
/// </summary>
public static class CodexUsageParser
{
    // ------------------------------------------------------------------
    // wham/usage 响应（OAuth / PAT 同路径）。
    // ------------------------------------------------------------------

    /// <summary>
    /// 损失容忍解码 wham/usage 响应（Swift: JSONDecoder().decode(CodexUsageResponse.self)）。
    /// 非对象 JSON 抛 <see cref="CodexUsageParseException"/>（等价 Swift 侧折叠为 invalidResponse）；
    /// 字段级畸形一律降级为 null + 解码失败标志，不影响兄弟字段。
    /// </summary>
    public static CodexUsageResponse ParseUsageResponse(string json)
    {
        JsonElement root;
        try
        {
            using var document = JsonDocument.Parse(json);
            root = document.RootElement.Clone();
        }
        catch (JsonException)
        {
            throw new CodexUsageParseException("Invalid JSON");
        }

        if (root.ValueKind != JsonValueKind.Object)
        {
            throw new CodexUsageParseException("Invalid JSON");
        }

        var rateLimit = root.TryGetProperty("rate_limit", out var rateLimitElement) &&
            rateLimitElement.ValueKind == JsonValueKind.Object
                ? ParseRateLimitDetails(rateLimitElement)
                : null;

        var accountId = CodexJson.String(root, "account_id", "accountId");
        var credits = root.TryGetProperty("credits", out var creditsElement) &&
            creditsElement.ValueKind == JsonValueKind.Object
                ? ParseCreditDetails(creditsElement)
                : null;

        var individualLimit = root.TryGetProperty("individual_limit", out var individualElement) &&
            individualElement.ValueKind == JsonValueKind.Object
                ? ParseSpendControlLimit(individualElement)
                : null;

        var spendControlPresent =
            (root.TryGetProperty("spend_control", out var spendControlElement) &&
                spendControlElement.ValueKind != JsonValueKind.Null) ||
            (root.TryGetProperty("spendControl", out var spendControlCamelElement) &&
                spendControlCamelElement.ValueKind != JsonValueKind.Null);
        var spendControlIndividualLimit =
            ParseSpendControlWrapper(root, "spend_control") ?? ParseSpendControlWrapper(root, "spendControl");

        var (additionalRateLimits, additionalDecodeFailed) = ParseAdditionalRateLimits(root);

        return new CodexUsageResponse(
            AccountId: accountId,
            PlanType: CodexJson.String(root, "plan_type"),
            RateLimit: rateLimit,
            Credits: credits,
            IndividualLimit: individualLimit,
            SpendControlIndividualLimit: spendControlIndividualLimit,
            SpendControlPresent: spendControlPresent,
            AdditionalRateLimits: additionalRateLimits,
            AdditionalRateLimitsDecodeFailed: additionalDecodeFailed);
    }

    /// <summary>
    /// usage 响应 → 中间快照（Swift: CodexReconciledState.fromOAuth/fromPAT + toUsageSnapshot）。
    /// OAuth 与 PAT 的差别只在身份来源：OAuth 从凭据 id_token JWT 解析邮箱/计划，
    /// PAT 从 whoami 解析。窗口归一后 primary/secondary 皆无 → null（额外窗口不能单独救活快照）。
    /// </summary>
    public static CodexUsageSnapshot? MapUsageSnapshot(
        CodexUsageResponse response,
        CodexOAuthCredentials? credentials = null,
        CodexPatWhoami? whoami = null,
        DateTimeOffset now = default)
    {
        var primary = MakeWindow(response.RateLimit?.PrimaryWindow);
        var secondary = MakeWindow(response.RateLimit?.SecondaryWindow);
        var extras = CodexAdditionalRateLimitMapper.ExtraRateWindows(response.AdditionalRateLimits);

        var (normalizedPrimary, normalizedSecondary) = CodexRateWindowNormalizer.Normalize(primary, secondary);
        if (normalizedPrimary is null && normalizedSecondary is null)
        {
            return null;
        }

        var identity = credentials is not null
            ? OAuthIdentity(response, credentials)
            : PatIdentity(response, whoami);

        // Swift: makeResult —— 窗口解码有损（主/周或额外限额）→ unknown，否则 exact。
        var confidence = response.HasWindowDecodeFailure || response.AdditionalRateLimitsDecodeFailed
            ? CodexDataConfidence.Unknown
            : CodexDataConfidence.Exact;

        return new CodexUsageSnapshot(
            Primary: normalizedPrimary,
            Secondary: normalizedSecondary,
            Tertiary: null,
            ExtraRateWindows: extras.Count == 0 ? null : extras,
            ProviderCost: null,
            UpdatedAt: now,
            Identity: identity,
            DataConfidence: confidence);
    }

    /// <summary>
    /// usage 响应 → 积分快照（Swift: CodexOAuthFetchStrategy.mapCredits）。balance、个人限额、
    /// credits 声明三者皆无 → null；仅声明 has_credits=true 也构成一条积分快照。
    /// </summary>
    public static CodexCreditsSnapshot? MapCredits(
        CodexUsageResponse response,
        DateTimeOffset updatedAt,
        bool includeCredits = true)
    {
        var balance = response.Credits?.Balance;
        var creditLimit = ToCreditLimit(response.ResolvedIndividualLimit, updatedAt);
        var creditsAvailable = response.Credits is { } credits
            ? credits.HasCredits && !credits.Unlimited
            : null;

        if (balance is null && creditLimit is null && creditsAvailable != true)
        {
            return null;
        }

        return new CodexCreditsSnapshot(
            Remaining: balance ?? 0,
            UpdatedAt: updatedAt,
            CreditLimit: creditLimit,
            BalanceReadSucceeded: balance is not null,
            CreditsAvailable: includeCredits || balance is not null ? creditsAvailable : null,
            BalanceIsWorkspace: false);
    }

    /// <summary>
    /// usage 响应 → 应用层 <see cref="Contracts.UsageData"/> 的完整解析管线（网络富集除外）。
    /// 无窗口时保留部分结果（credits-only / 未配置占位），镜像 Swift makeResult 的部分结果语义。
    /// </summary>
    /// <param name="response">已解码的 usage 响应。</param>
    /// <param name="credentials">OAuth 凭据（OAuth 源身份解析用；PAT 源传 null）。</param>
    /// <param name="whoami">PAT 身份（PAT 源传；OAuth 源传 null）。</param>
    /// <param name="sourceLabel">数据来源标签（oauth / pat / codex-cli …），写入 detailText。</param>
    /// <param name="now">解析基准时间（重置倒计时与 dataConfidence 时间戳）。</param>
    /// <param name="includeCredits">是否请求积分（Swift: ProviderFetchContext.includeCredits）。</param>
    public static UsageData MapToUsageData(
        CodexUsageResponse response,
        CodexOAuthCredentials? credentials,
        CodexPatWhoami? whoami,
        string sourceLabel,
        DateTimeOffset now,
        bool includeCredits = true)
    {
        var snapshot = MapUsageSnapshot(response, credentials, whoami, now);
        var credits = MapCredits(response, snapshot?.UpdatedAt ?? now, includeCredits);
        if (snapshot is null)
        {
            snapshot = new CodexUsageSnapshot(
                Primary: null,
                Secondary: null,
                Tertiary: null,
                ExtraRateWindows: null,
                ProviderCost: null,
                UpdatedAt: now,
                Identity: credentials is not null ? OAuthIdentity(response, credentials) : PatIdentity(response, whoami),
                DataConfidence: CodexDataConfidence.Unknown);
        }

        return CodexUsageDataMapper.MapToUsageData(snapshot, credits, sourceLabel, now);
    }

    // ------------------------------------------------------------------
    // PAT whoami。
    // ------------------------------------------------------------------

    /// <summary>
    /// 解析 whoami（Swift: WhoamiResponse.model）。字段 trim 后空白视为 null；
    /// 非对象 JSON 抛 <see cref="CodexUsageParseException"/>。
    /// </summary>
    public static CodexPatWhoami ParseWhoami(string json)
    {
        var root = ParseObjectOrThrow(json);
        return new CodexPatWhoami(
            AccountId: NonEmpty(CodexJson.String(root, "chatgpt_account_id")),
            Email: NonEmpty(CodexJson.String(root, "email")),
            PlanType: NonEmpty(CodexJson.String(root, "chatgpt_plan_type")));
    }

    // ------------------------------------------------------------------
    // rate-limit-reset-credits。
    // ------------------------------------------------------------------

    /// <summary>
    /// 解析 rate-limit-reset-credits（Swift: fetchRateLimitResetCredits 的解码分支 + 负数拒绝）。
    /// available_count 为负 → 抛 <see cref="CodexUsageParseException"/>；该接口失败不影响主额度
    /// （容错由上层编排负责）。credits[].id 做 stableID 哈希。
    /// </summary>
    public static CodexRateLimitResetCreditsSnapshot ParseRateLimitResetCredits(
        string json,
        DateTimeOffset now)
    {
        var root = ParseObjectOrThrow(json);

        if (!root.TryGetProperty("credits", out var creditsElement) ||
            creditsElement.ValueKind != JsonValueKind.Array)
        {
            throw new CodexUsageParseException("Missing credits array");
        }

        var availableCount = CodexJson.Int32(root, "available_count")
            ?? throw new CodexUsageParseException("Missing available_count");
        if (availableCount < 0)
        {
            throw new CodexUsageParseException("Negative available_count");
        }

        var credits = new List<CodexRateLimitResetCredit>();
        foreach (var element in creditsElement.EnumerateArray())
        {
            if (element.ValueKind != JsonValueKind.Object)
            {
                throw new CodexUsageParseException("Invalid credit entry");
            }

            var providerId = CodexJson.String(element, "id")
                ?? throw new CodexUsageParseException("Missing credit id");
            var resetType = CodexJson.String(element, "reset_type")
                ?? throw new CodexUsageParseException("Missing reset_type");
            var status = CodexJson.String(element, "status")
                ?? throw new CodexUsageParseException("Missing status");
            var grantedAt = CodexJson.Iso8601(CodexJson.String(element, "granted_at"))
                ?? throw new CodexUsageParseException("Missing granted_at");

            var stableId = CodexRateLimitResetCredit.IsCanonicalStableId(providerId)
                ? providerId
                : CodexRateLimitResetCredit.StableIdFor(providerId);

            credits.Add(new CodexRateLimitResetCredit(
                Id: stableId,
                ResetType: resetType,
                Status: status,
                GrantedAt: grantedAt,
                ExpiresAt: CodexJson.Iso8601(CodexJson.String(element, "expires_at")),
                RedeemStartedAt: CodexJson.Iso8601(CodexJson.String(element, "redeem_started_at")),
                RedeemedAt: CodexJson.Iso8601(CodexJson.String(element, "redeemed_at")),
                Title: CodexJson.String(element, "title"),
                Description: CodexJson.String(element, "description")));
        }

        return new CodexRateLimitResetCreditsSnapshot(credits, availableCount, now);
    }

    // ------------------------------------------------------------------
    // 工作区剩余积分。
    // ------------------------------------------------------------------

    /// <summary>
    /// 解析 remaining_balance（Swift: CodexWorkspaceRemainingBalanceResponse）：数字，或 trim 后
    /// 可解析字符串；非有限 → null；负数钳 0。字段缺失/类型不符 → null（调用方按“无余额”处理）。
    /// </summary>
    public static CodexWorkspaceRemainingBalance ParseWorkspaceRemainingBalance(string json)
    {
        var root = ParseObjectOrThrow(json);
        if (!root.TryGetProperty("balance", out var balanceElement) ||
            balanceElement.ValueKind == JsonValueKind.Null)
        {
            return new CodexWorkspaceRemainingBalance(null);
        }

        double? parsed = balanceElement.ValueKind switch
        {
            JsonValueKind.Number => balanceElement.GetDouble(),
            JsonValueKind.String => ParseFiniteString(balanceElement.GetString()),
            _ => null,
        };

        if (parsed is not { } value || !double.IsFinite(value))
        {
            return new CodexWorkspaceRemainingBalance(null);
        }

        return new CodexWorkspaceRemainingBalance(Math.Max(0, value));
    }

    private static double? ParseFiniteString(string? text)
    {
        var trimmed = text?.Trim();
        if (trimmed is null)
        {
            return null;
        }

        // Swift Double(String) 不接受 NaN/Infinity 字样；C# TryParse 接受，需显式拒绝。
        if (double.TryParse(trimmed, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var value) &&
            double.IsFinite(value))
        {
            return value;
        }

        return null;
    }

    // ------------------------------------------------------------------
    // App 层 UsageSnapshot 线上形态（camelCase + ISO 8601）。
    // ------------------------------------------------------------------

    /// <summary>
    /// 解析 App 层快照线上形态（Swift: UsageSnapshot Codable init；契约样本
    /// usage-snapshot-current.json）。identity 缺失时回退顶层 accountEmail/accountOrganization/
    /// loginMethod（旧形态）；dataConfidence 未知原串按 Unknown。
    /// </summary>
    public static CodexUsageSnapshot ParseUsageSnapshot(string json)
    {
        var root = ParseObjectOrThrow(json);

        var primary = ParseRateWindowProperty(root, "primary");
        var secondary = ParseRateWindowProperty(root, "secondary");
        var tertiary = ParseRateWindowProperty(root, "tertiary");

        IReadOnlyList<CodexNamedRateWindow>? extras = null;
        if (root.TryGetProperty("extraRateWindows", out var extrasElement) &&
            extrasElement.ValueKind == JsonValueKind.Array)
        {
            var list = new List<CodexNamedRateWindow>();
            foreach (var element in extrasElement.EnumerateArray())
            {
                if (element.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }

                var id = CodexJson.String(element, "id") ?? string.Empty;
                var title = CodexJson.String(element, "title") ?? string.Empty;
                if (element.TryGetProperty("window", out var windowElement))
                {
                    list.Add(new CodexNamedRateWindow(id, title, ParseRateWindowObject(windowElement)));
                }
            }

            extras = list;
        }

        CodexProviderCostSnapshot? providerCost = null;
        if (root.TryGetProperty("providerCost", out var costElement) &&
            costElement.ValueKind == JsonValueKind.Object)
        {
            providerCost = new CodexProviderCostSnapshot(
                Used: CodexJson.FlexibleDouble(costElement, "used") ?? 0,
                Limit: CodexJson.FlexibleDouble(costElement, "limit") ?? 0,
                CurrencyCode: CodexJson.String(costElement, "currencyCode") ?? "USD",
                Period: CodexJson.String(costElement, "period"),
                ResetsAt: CodexJson.Iso8601(CodexJson.String(costElement, "resetsAt")),
                Balance: CodexJson.FlexibleDouble(costElement, "balance"),
                BalanceUpdatedAt: CodexJson.Iso8601(CodexJson.String(costElement, "balanceUpdatedAt")),
                BalanceIsWorkspace: BoolOrNull(costElement, "balanceIsWorkspace"),
                UpdatedAt: CodexJson.Iso8601(CodexJson.String(costElement, "updatedAt")) ?? default);
        }

        var updatedAt = CodexJson.Iso8601(CodexJson.String(root, "updatedAt"))
            ?? throw new CodexUsageParseException("Missing updatedAt");

        var identity = ParseIdentity(root);

        var confidence = CodexDataConfidence.Unknown;
        if (CodexJson.String(root, "dataConfidence") is { } confidenceRaw)
        {
            confidence = confidenceRaw switch
            {
                "exact" => CodexDataConfidence.Exact,
                "estimated" => CodexDataConfidence.Estimated,
                "percentOnly" => CodexDataConfidence.PercentOnly,
                _ => CodexDataConfidence.Unknown,
            };
        }

        return new CodexUsageSnapshot(
            Primary: primary,
            Secondary: secondary,
            Tertiary: tertiary,
            ExtraRateWindows: extras,
            ProviderCost: providerCost,
            UpdatedAt: updatedAt,
            Identity: identity,
            DataConfidence: confidence);
    }

    // ------------------------------------------------------------------
    // 内部：usage 响应解码。
    // ------------------------------------------------------------------

    private static CodexUsageResponse.RateLimitDetails? ParseRateLimitDetails(JsonElement element)
    {
        var (primaryWindow, primaryFailed) = ParseWindow(element, "primary_window");
        var (secondaryWindow, secondaryFailed) = ParseWindow(element, "secondary_window");

        var individualLimit = element.TryGetProperty("individual_limit", out var individualElement) &&
            individualElement.ValueKind == JsonValueKind.Object
                ? ParseSpendControlLimit(individualElement)
                : null;
        individualLimit ??= element.TryGetProperty("individualLimit", out var individualCamelElement) &&
            individualCamelElement.ValueKind == JsonValueKind.Object
                ? ParseSpendControlLimit(individualCamelElement)
                : null;

        return new CodexUsageResponse.RateLimitDetails(
            PrimaryWindow: primaryWindow,
            SecondaryWindow: secondaryWindow,
            IndividualLimit: individualLimit,
            PrimaryWindowDecodeFailed: primaryFailed,
            SecondaryWindowDecodeFailed: secondaryFailed);
    }

    private static (CodexUsageResponse.WindowSnapshot? Window, bool DecodeFailed) ParseWindow(
        JsonElement element,
        string key)
    {
        var hadValue = CodexJson.HasNonNull(element, key);
        if (!hadValue)
        {
            return (null, false);
        }

        if (element.TryGetProperty(key, out var windowElement) &&
            windowElement.ValueKind == JsonValueKind.Object &&
            CodexJson.Int32(windowElement, "used_percent") is { } usedPercent &&
            CodexJson.Int32(windowElement, "reset_at") is { } resetAt &&
            CodexJson.Int32(windowElement, "limit_window_seconds") is { } limitWindowSeconds)
        {
            return (new CodexUsageResponse.WindowSnapshot(usedPercent, resetAt, limitWindowSeconds), false);
        }

        return (null, true);
    }

    private static CodexUsageResponse.CreditDetails ParseCreditDetails(JsonElement element) =>
        new(
            HasCredits: CodexJson.BoolOrFalse(element, "has_credits"),
            Unlimited: CodexJson.BoolOrFalse(element, "unlimited"),
            Balance: CodexJson.FlexibleDouble(element, "balance"));

    private static CodexUsageResponse.SpendControlLimitSnapshot? ParseSpendControlLimit(JsonElement element) =>
        new(
            Limit: CodexJson.FlexibleDouble(element, "limit"),
            Used: CodexJson.FlexibleDouble(element, "used"),
            RemainingPercent: CodexJson.FlexibleDouble(element, "remainingPercent", "remaining_percent"),
            ResetsAt: CodexJson.FlexibleInt32(element, "resetsAt", "resets_at", "reset_at"));

    private static CodexUsageResponse.SpendControlLimitSnapshot? ParseSpendControlWrapper(
        JsonElement root,
        string key)
    {
        if (!root.TryGetProperty(key, out var wrapper) || wrapper.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        return wrapper.TryGetProperty("individual_limit", out var individual) &&
            individual.ValueKind == JsonValueKind.Object
                ? ParseSpendControlLimit(individual)
                : wrapper.TryGetProperty("individualLimit", out var individualCamel) &&
                    individualCamel.ValueKind == JsonValueKind.Object
                        ? ParseSpendControlLimit(individualCamel)
                        : null;
    }

    private static (IReadOnlyList<CodexUsageResponse.AdditionalRateLimit>? Limits, bool DecodeFailed)
        ParseAdditionalRateLimits(JsonElement root)
    {
        if (!root.TryGetProperty("additional_rate_limits", out var element) ||
            element.ValueKind == JsonValueKind.Null)
        {
            return (null, false);
        }

        if (element.ValueKind != JsonValueKind.Array)
        {
            // 非数组（如字符串）→ 整体丢弃并记失败（Swift: catch 分支 additionalRateLimitsDecodeFailed=hadValue）。
            return (null, true);
        }

        var limits = new List<CodexUsageResponse.AdditionalRateLimit>();
        var decodeFailed = false;
        foreach (var item in element.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object)
            {
                // 非对象兄弟元素直接跳过（LossyAdditionalRateLimit），不影响合法条目。
                decodeFailed = true;
                continue;
            }

            var limitName = CodexJson.String(item, "limit_name");
            var meteredFeature = CodexJson.String(item, "metered_feature");

            var rateLimitHadValue = CodexJson.HasNonNull(item, "rate_limit");
            CodexUsageResponse.RateLimitDetails? rateLimit = null;
            var rateLimitFailed = false;
            if (rateLimitHadValue)
            {
                if (item.TryGetProperty("rate_limit", out var rateLimitElement) &&
                    rateLimitElement.ValueKind == JsonValueKind.Object)
                {
                    rateLimit = ParseRateLimitDetails(rateLimitElement);
                }
                else
                {
                    rateLimitFailed = true;
                }
            }

            var entry = new CodexUsageResponse.AdditionalRateLimit(
                LimitName: limitName,
                MeteredFeature: meteredFeature,
                RateLimit: rateLimit,
                RateLimitDecodeFailed: rateLimitFailed);
            limits.Add(entry);
            decodeFailed = decodeFailed || entry.HasWindowDecodeFailure;
        }

        return (limits, decodeFailed);
    }

    // ------------------------------------------------------------------
    // 内部：窗口 / 身份 / 限额。
    // ------------------------------------------------------------------

    private static CodexRateWindow? MakeWindow(CodexUsageResponse.WindowSnapshot? snapshot)
    {
        if (snapshot is null)
        {
            return null;
        }

        return new CodexRateWindow(
            UsedPercent: snapshot.UsedPercent,
            WindowMinutes: snapshot.LimitWindowSeconds / 60,
            ResetsAt: DateTimeOffset.FromUnixTimeSeconds(snapshot.ResetAt),
            ResetDescription: null);
    }

    private static CodexProviderIdentity OAuthIdentity(
        CodexUsageResponse response,
        CodexOAuthCredentials credentials) =>
        new(
            ProviderId: "codex",
            AccountEmail: ResolveOAuthAccountEmail(credentials),
            AccountOrganization: null,
            LoginMethod: ResolveOAuthPlan(response, credentials));

    private static CodexProviderIdentity PatIdentity(
        CodexUsageResponse response,
        CodexPatWhoami? whoami) =>
        new(
            ProviderId: "codex",
            AccountEmail: whoami?.Email,
            AccountOrganization: null,
            LoginMethod: ResolvePatPlan(response, whoami));

    /// <summary>Swift: resolveAccountEmail —— 仅从 id_token JWT：email 或 profile.email。</summary>
    private static string? ResolveOAuthAccountEmail(CodexOAuthCredentials credentials)
    {
        if (CodexJwt.TryGetPayload(credentials.IdToken) is not { } payload)
        {
            return null;
        }

        var email =
            CodexJson.String(payload, "email") ??
            (payload.TryGetProperty("https://api.openai.com/profile", out var profile) &&
                profile.ValueKind == JsonValueKind.Object
                ? CodexJson.String(profile, "email")
                : null);
        return NonEmpty(email);
    }

    /// <summary>Swift: resolvePlan —— 响应 plan_type 优先，缺失时从 id_token JWT 的计划声明恢复。</summary>
    private static string? ResolveOAuthPlan(CodexUsageResponse response, CodexOAuthCredentials credentials)
    {
        if (NonEmpty(response.PlanType) is { } plan)
        {
            return plan;
        }

        if (CodexJwt.TryGetPayload(credentials.IdToken) is not { } payload)
        {
            return null;
        }

        var planClaim =
            (payload.TryGetProperty("https://api.openai.com/auth", out var auth) &&
                auth.ValueKind == JsonValueKind.Object
                ? CodexJson.String(auth, "chatgpt_plan_type")
                : null) ??
            CodexJson.String(payload, "chatgpt_plan_type");
        return NonEmpty(planClaim);
    }

    /// <summary>Swift: resolvePATPlan —— 响应 plan_type 优先，缺失时用 whoami 的计划。</summary>
    private static string? ResolvePatPlan(CodexUsageResponse response, CodexPatWhoami? whoami) =>
        NonEmpty(response.PlanType) ?? whoami?.PlanType;

    /// <summary>Swift: CodexSpendControlLimitMapping.codexCreditLimitSnapshot。</summary>
    internal static CodexCreditLimitSnapshot? ToCreditLimit(
        CodexUsageResponse.SpendControlLimitSnapshot? snapshot,
        DateTimeOffset updatedAt)
    {
        if (snapshot is null || snapshot.Limit is not { } limit || limit <= 0)
        {
            return null;
        }

        var used = snapshot.Used ??
            (snapshot.RemainingPercent is { } remainingPercent
                ? ComputeUsedFromRemaining(limit, remainingPercent)
                : 0);
        var finalRemainingPercent = snapshot.RemainingPercent ??
            Math.Max(0, Math.Min(100, 100 - used / limit * 100));
        var resetsAt = snapshot.ResetsAt is > 0
            ? DateTimeOffset.FromUnixTimeSeconds(snapshot.ResetsAt.Value)
            : null;

        return new CodexCreditLimitSnapshot(
            title: null,
            used: used,
            limit: limit,
            remainingPercent: finalRemainingPercent,
            resetsAt: resetsAt,
            updatedAt: updatedAt);

        static double ComputeUsedFromRemaining(double limit, double remainingPercent) =>
            limit * Math.Max(0, Math.Min(100, 100 - remainingPercent)) / 100;
    }

    // ------------------------------------------------------------------
    // 内部：usage-snapshot 线上形态。
    // ------------------------------------------------------------------

    private static CodexRateWindow? ParseRateWindowProperty(JsonElement root, string key)
    {
        if (!root.TryGetProperty(key, out var element) || element.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        return ParseRateWindowObject(element);
    }

    private static CodexRateWindow ParseRateWindowObject(JsonElement element)
    {
        // usedPercent 为必填（Swift: decode(Double) 缺失即整个快照解码失败）。
        if (!element.TryGetProperty("usedPercent", out var usedElement) ||
            usedElement.ValueKind != JsonValueKind.Number)
        {
            throw new CodexUsageParseException("Missing usedPercent");
        }

        var windowMinutes = CodexJson.Int32(element, "windowMinutes");
        var resetsAt = CodexJson.Iso8601(CodexJson.String(element, "resetsAt"));
        var resetDescription = CodexJson.String(element, "resetDescription");

        return new CodexRateWindow(usedElement.GetDouble(), windowMinutes, resetsAt, resetDescription);
    }

    private static CodexProviderIdentity? ParseIdentity(JsonElement root)
    {
        if (root.TryGetProperty("identity", out var identityElement) &&
            identityElement.ValueKind == JsonValueKind.Object)
        {
            return new CodexProviderIdentity(
                ProviderId: CodexJson.String(identityElement, "providerID"),
                AccountEmail: CodexJson.String(identityElement, "accountEmail"),
                AccountOrganization: CodexJson.String(identityElement, "accountOrganization"),
                LoginMethod: CodexJson.String(identityElement, "loginMethod"),
                AccountId: CodexJson.String(identityElement, "accountID"));
        }

        var email = CodexJson.String(root, "accountEmail");
        var organization = CodexJson.String(root, "accountOrganization");
        var loginMethod = CodexJson.String(root, "loginMethod");
        if (email is null && organization is null && loginMethod is null)
        {
            return null;
        }

        return new CodexProviderIdentity(null, email, organization, loginMethod);
    }

    private static bool? BoolOrNull(JsonElement element, string key)
    {
        if (element.ValueKind == JsonValueKind.Object &&
            element.TryGetProperty(key, out var value))
        {
            return value.ValueKind switch
            {
                JsonValueKind.True => true,
                JsonValueKind.False => false,
                _ => null,
            };
        }

        return null;
    }

    private static JsonElement ParseObjectOrThrow(string json)
    {
        JsonElement root;
        try
        {
            using var document = JsonDocument.Parse(json);
            root = document.RootElement.Clone();
        }
        catch (JsonException)
        {
            throw new CodexUsageParseException("Invalid JSON");
        }

        if (root.ValueKind != JsonValueKind.Object)
        {
            throw new CodexUsageParseException("Invalid JSON");
        }

        return root;
    }

    private static string? NonEmpty(string? value)
    {
        var trimmed = value?.Trim();
        return string.IsNullOrEmpty(trimmed) ? null : trimmed;
    }
}
