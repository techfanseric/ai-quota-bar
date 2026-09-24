// Swift 来源：AIQuotaBar/Services/ProviderLocalActivitySnapshot.swift — struct ProviderLocalActivitySnapshot。
//
// TODO(W1): Swift 侧该类型是跨 provider 共享（ZCode / Claude Code / MiniMax），归属 Core；
// 本目录不拥有 Core / Providers 根，暂落在 Minimax/ 下。编排者落地 Core 版本时应把本记录上移并让
// 各 provider 检测器引用之（届时删除本文件即可，测试同步改命名空间）。

namespace AIQuotaBar.Providers.Minimax;

/// <summary>
/// 被动本地检测器的活动快照（Swift: ProviderLocalActivitySnapshot）。只读生命周期元数据；
/// 消息体与工具输出永不保留。会话 ID 预先带上 provider 与客户端前缀（如 minimax:cli:&lt;id&gt;）。
/// </summary>
/// <param name="ActiveSessionIds">新鲜度窗口内的会话 ID 集合。</param>
/// <param name="LastEventAt">全部会话中最近一次事件时间。</param>
/// <param name="LastEventBySession">每会话最近事件时间。</param>
public sealed record ProviderLocalActivitySnapshot(
    IReadOnlyCollection<string> ActiveSessionIds,
    DateTimeOffset? LastEventAt,
    IReadOnlyDictionary<string, DateTimeOffset> LastEventBySession)
{
    /// <summary>Swift: ProviderLocalActivitySnapshot.empty。</summary>
    public static ProviderLocalActivitySnapshot Empty { get; } = new(
        Array.Empty<string>(),
        null,
        new Dictionary<string, DateTimeOffset>());
}
