// Swift 来源：无（Windows 端新增；对齐 Glm/GlmUsageException.cs 的 provider 内部异常承载方式）。
//   语义对应 Win-CodexBar rust/src/providers/codex/mod.rs 的 ProviderError（authRequired / network /
//   apiError——见 api.rs fetch_usage_once 对 401 与非 2xx 的分类）与 codexbar Swift 侧 UsageError。
// TODO(编排者暂缓项)：随 GlmUsageException 一并收敛为共享 UsageError 枚举（GlmUsageException.cs 头注同条）。

#nullable enable

using System;

namespace AIQuotaBar.Providers.Codex;

/// <summary>Codex usage 拉取错误分类。成员语义对齐 Win-CodexBar ProviderError 的相关 case。</summary>
public enum CodexUsageError
{
    /// <summary>凭据未配置（空 API key 输入）——对齐 Swift UsageError.notConfigured。</summary>
    NotConfigured,

    /// <summary>传输层失败（连接 / 超时）——对齐 Swift UsageError.networkError。</summary>
    NetworkError,

    /// <summary>
    /// 服务端拒绝凭据（HTTP 401）。Win-CodexBar：authenticated_http_error 把 401 折叠为
    /// AuthRequired（与 403 等其余错误区分），消息携带 re-login 提示。
    /// </summary>
    AuthRequired,

    /// <summary>其余非 2xx 服务端响应（含 403），消息携带响应体摘录。</summary>
    ApiError,
}

/// <summary>
/// Codex usage 端点异常。<see cref="Kind"/> 承载判别语义，<see cref="StatusCode"/> 保留
/// HTTP 状态码（网络错误为 null），Message 承载用户可见详情。
/// </summary>
public sealed class CodexUsageException : Exception
{
    public CodexUsageException(CodexUsageError kind, string message, int? statusCode = null)
        : base(message)
    {
        Kind = kind;
        StatusCode = statusCode;
    }

    public CodexUsageException(
        CodexUsageError kind,
        string message,
        Exception innerException,
        int? statusCode = null)
        : base(message, innerException)
    {
        Kind = kind;
        StatusCode = statusCode;
    }

    public CodexUsageError Kind { get; }

    /// <summary>HTTP 状态码；传输层失败（NetworkError）与未发请求（NotConfigured）为 null。</summary>
    public int? StatusCode { get; }
}
