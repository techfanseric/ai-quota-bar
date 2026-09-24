// Swift 来源：无（Windows 端新增——Swift 直接 throws ClashIntegrationError 枚举，
// C# 需要异常类型承载；Error 属性保留 record 值语义供测试断言）。

#nullable enable

using System;

namespace AIQuotaBar.Providers.Clash;

/// <summary>携带 <see cref="ClashIntegrationError"/> 的异常；捕获方按 Error 分支处理。</summary>
public sealed class ClashIntegrationException : Exception
{
    public ClashIntegrationError Error { get; }

    public ClashIntegrationException(ClashIntegrationError error)
        : base(error.Description)
    {
        Error = error;
    }
}
