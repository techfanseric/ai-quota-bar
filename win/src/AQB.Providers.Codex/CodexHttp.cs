namespace AQB.Providers.Codex;

public static class CodexHttp
{
    public static string DescribeFailure(HttpRequestException error)
    {
        var messages = new List<string>();
        for (Exception? current = error; current is not null; current = current.InnerException)
        {
            if (!messages.Contains(current.Message)) messages.Add(current.Message);
        }

        return string.Join(" → ", messages);
    }
    /// <summary>
    /// Default handler honoring the system proxy (WinINET settings), matching the macOS
    /// behaviour where URLSession provider requests inherit the system proxy — chatgpt.com
    /// is expected to be reached through proxies like Clash. Only loopback clients
    /// (AQB.Clash controller) bypass the proxy.
    /// </summary>
    public static HttpMessageHandler CreateDefaultHandler() => new HttpClientHandler();
}
