namespace AQB.Providers.Codex;

internal static class CodexHttp
{
    /// <summary>
    /// Default handler. UseProxy = false bypasses any system proxy (WinHTTP/IE settings),
    /// matching the macOS behaviour where requests never go through the system proxy.
    /// </summary>
    public static HttpMessageHandler CreateDefaultHandler() => new HttpClientHandler
    {
        UseProxy = false,
    };
}
