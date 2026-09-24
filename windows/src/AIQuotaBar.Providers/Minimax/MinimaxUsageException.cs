// Swift 来源：AIQuotaBar/Models/UsageData.swift:773-784 — enum UsageError（macOS 端 MiniMax 沿用）；
// codexbar 侧错误判别：.dependencies/codexbar/Sources/CodexBarCore/Providers/MiniMax/MiniMaxUsageError.swift
// （invalidCredentials / networkError / apiError / parseFailed）。
//
// UsageError 统一枚举是契约 agent 的暂缓项（本目录不拥有 Providers 根 / Core）：MiniMax 侧先以 provider
// 内部异常承载错误语义，Kind 覆盖 macOS UsageError 与 codexbar MiniMaxUsageError 的并集；
// 待编排者落地共享 UsageError 后与 Glm/GlmUsageException.cs 一并统一（TODO(W1)）。

namespace AIQuotaBar.Providers.Minimax;

/// <summary>MiniMax 用量错误分类。InvalidCredentials 对应 codexbar MiniMaxUsageError.invalidCredentials。</summary>
public enum MinimaxUsageErrorKind
{
    /// <summary>Swift: UsageError.networkError — 传输层失败（连接 / 超时）。</summary>
    NetworkError,

    /// <summary>codexbar: MiniMaxUsageError.invalidCredentials — 401/403、base_resp 1004 或登录态失效文案。</summary>
    InvalidCredentials,

    /// <summary>Swift: UsageError.invalidResponse（含 codexbar parseFailed“缺 coding plan 数据”）。</summary>
    InvalidResponse,

    /// <summary>Swift: UsageError.apiError — 服务端错误体（base_resp 非 0 / HTTP 非 2xx）。</summary>
    ApiError,

    /// <summary>Swift: UsageError.notConfigured — 凭据未配置（空 token）。</summary>
    NotConfigured,
}

/// <summary>
/// MiniMax provider 的用量异常。<see cref="Kind"/> 承载错误分类，
/// <see cref="Exception.Message"/> 承载错误详情（base_resp.status_msg / HTTP 状态）。
/// </summary>
public sealed class MinimaxUsageException : Exception
{
    public MinimaxUsageException(MinimaxUsageErrorKind kind, string message)
        : base(message)
    {
        Kind = kind;
    }

    public MinimaxUsageException(MinimaxUsageErrorKind kind, string message, Exception innerException)
        : base(message, innerException)
    {
        Kind = kind;
    }

    public MinimaxUsageErrorKind Kind { get; }
}
