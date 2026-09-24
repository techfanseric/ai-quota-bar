// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/Providers/MiniMax/MiniMaxAPIRegion.swift
// — enum MiniMaxAPIRegion（API 端点族）。macOS 端 AIQuotaBar 未实现 MiniMax 用量拉取（仅本地活动检测），
// Windows 端 MiniMax 拉取契约基准是 codexbar（windows/contracts/fixtures/MANIFEST.md minimax 节）。
//
// 端点（codexbar 原值）：
//   Global        api.minimax.io  — v1/token_plan/remains（首选）、v1/api/openplatform/coding_plan/remains（legacy）
//   ChinaMainland api.minimaxi.com — 同路径
// 注意：MANIFEST 里把 token-plan 端点写作 platform.minimax.io，与 codexbar 实现（api.minimax.io）不一致；
// 本文件按“以 codexbar 实现为准”的裁决取 api 子域，差异已上报编排者。

namespace AIQuotaBar.Providers.Minimax;

/// <summary>MiniMax API 区域（Swift: MiniMaxAPIRegion）。决定用量端点的 host 族。</summary>
public enum MinimaxApiRegion
{
    /// <summary>Global（api.minimax.io）。</summary>
    Global,

    /// <summary>中国大陆（api.minimaxi.com）。</summary>
    ChinaMainland,
}

/// <summary>MiniMax 区域端点（Swift: MiniMaxAPIRegion 的 tokenPlanRemainsURL / apiRemainsURL）。</summary>
public static class MinimaxApiRegions
{
    /// <summary>首选 token-plan 端点（Swift: region.tokenPlanRemainsURL）。</summary>
    public static Uri TokenPlanRemainsUrl(this MinimaxApiRegion region) =>
        new(BaseUrl(region) + "v1/token_plan/remains");

    /// <summary>legacy coding-plan 端点（Swift: region.apiRemainsURL）。</summary>
    public static Uri CodingPlanRemainsUrl(this MinimaxApiRegion region) =>
        new(BaseUrl(region) + "v1/api/openplatform/coding_plan/remains");

    private static string BaseUrl(MinimaxApiRegion region) => region switch
    {
        MinimaxApiRegion.Global => "https://api.minimax.io/",
        MinimaxApiRegion.ChinaMainland => "https://api.minimaxi.com/",
        _ => throw new ArgumentOutOfRangeException(nameof(region), region, null),
    };
}
