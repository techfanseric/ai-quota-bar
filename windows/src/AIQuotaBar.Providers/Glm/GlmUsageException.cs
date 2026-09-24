// Swift 来源：AIQuotaBar/Models/UsageData.swift:773-784 — enum UsageError（invalidURL / networkError /
// invalidResponse / apiError / notConfigured）。
//
// UsageError 统一枚举是契约 agent 的暂缓项（本目录不拥有 Providers 根 / Core）：GLM 侧先以
// provider 内部异常承载同等错误语义，Kind 与 Swift case 一一对应；待编排者落地共享 UsageError 后
// 应将本类型收敛为共享枚举的薄包装或直接替换（TODO(W1): 与 Minimax/MinimaxUsageException.cs 一并统一）。

namespace AIQuotaBar.Providers.Glm;

/// <summary>GLM 用量错误分类。成员与 Swift UsageError 的 GLM 相关 case 语义对齐。</summary>
public enum GlmUsageErrorKind
{
    /// <summary>Swift: UsageError.invalidURL — 凭据中的 API URL 无法解析。</summary>
    InvalidUri,

    /// <summary>Swift: UsageError.networkError — 传输层失败（连接 / 超时）。</summary>
    NetworkError,

    /// <summary>Swift: UsageError.invalidResponse — 载荷可读但不可用（空 limits / 非 PERSONAL / 解码失败）。</summary>
    InvalidResponse,

    /// <summary>Swift: UsageError.apiError — 服务端错误体（code != 200 / HTTP 非 2xx / msg）。</summary>
    ApiError,

    /// <summary>Swift: UsageError.notConfigured — 凭据未配置（空输入）。</summary>
    NotConfigured,
}

/// <summary>
/// GLM provider 的用量异常。<see cref="Kind"/> 承载 Swift UsageError 的判别语义，
/// <see cref="Exception.Message"/> 承载错误详情（Swift 携带的 msg / 状态文案）。
/// </summary>
public sealed class GlmUsageException : Exception
{
    public GlmUsageException(GlmUsageErrorKind kind, string message)
        : base(message)
    {
        Kind = kind;
    }

    public GlmUsageException(GlmUsageErrorKind kind, string message, Exception innerException)
        : base(message, innerException)
    {
        Kind = kind;
    }

    public GlmUsageErrorKind Kind { get; }
}
