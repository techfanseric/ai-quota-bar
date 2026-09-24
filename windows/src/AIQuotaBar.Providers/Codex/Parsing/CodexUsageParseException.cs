// Swift 来源：无（Windows 端新增）。Swift 侧各 fetcher 把 DecodingError 折叠为
//   CodexOAuthFetchError.invalidResponse；C# 解析层以本异常承载“响应不可用”语义。

#nullable enable

using System;

namespace AIQuotaBar.Providers.Codex.Parsing;

/// <summary>响应解码失败（等价 Swift CodexOAuthFetchError.invalidResponse 的解析部分）。</summary>
public sealed class CodexUsageParseException : Exception
{
    public CodexUsageParseException(string message)
        : base(message)
    {
    }
}
