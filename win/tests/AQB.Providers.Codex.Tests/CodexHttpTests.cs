using Xunit;

namespace AQB.Providers.Codex.Tests;

public class CodexHttpTests
{
    [Fact]
    public void DefaultHandlerHonorsSystemProxy()
    {
        var handler = Assert.IsType<HttpClientHandler>(CodexHttp.CreateDefaultHandler());

        Assert.True(handler.UseProxy);
    }
}
