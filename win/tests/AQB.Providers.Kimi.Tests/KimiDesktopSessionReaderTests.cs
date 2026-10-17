using System.Security.Cryptography;
using System.Text;
using Xunit;

namespace AQB.Providers.Kimi.Tests;

public class KimiDesktopSessionReaderTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "aqb-kimi-desktop-" + Guid.NewGuid().ToString("N"));

    private string WriteStore(string content)
    {
        Directory.CreateDirectory(_dir);
        var path = Path.Combine(_dir, "token-store.json");
        File.WriteAllText(path, content);
        return path;
    }

    private KimiDesktopSessionReader ReaderFor(string path)
        => new(windowsStorePath: path, macStorePath: Path.Combine(_dir, "missing-mac", "token-store.json"));

    [Fact]
    public void MissingFilesAreNotPresentAndLoadNull()
    {
        var reader = new KimiDesktopSessionReader(
            windowsStorePath: Path.Combine(_dir, "none1.json"),
            macStorePath: Path.Combine(_dir, "none2.json"));
        Assert.False(reader.IsPresent());
        Assert.Null(reader.TryLoad());
    }

    [Fact]
    public void PlainStoreYieldsAccessToken()
    {
        var path = WriteStore("""{"origin": "https://www.kimi.com", "tokens": {"access_token": "plain-token", "refresh_token": "ignored"}}""");
        var reader = ReaderFor(path);

        Assert.True(reader.IsPresent());
        var credential = reader.TryLoad();
        Assert.NotNull(credential);
        Assert.Equal("plain-token", credential!.Token);
        Assert.Equal("https://www.kimi.com", credential.Origin);
    }

    [Fact]
    public void PlainStoreWithoutOriginFallsBackToKimiCom()
    {
        var path = WriteStore("""{"tokens": {"access_token": "plain-token"}}""");
        var credential = ReaderFor(path).TryLoad();
        Assert.NotNull(credential);
        Assert.Equal("https://www.kimi.com", credential!.Origin);
    }

    [Fact]
    public void RefreshOnlyStoreReturnsNull()
    {
        var path = WriteStore("""{"tokens": {"refresh_token": "nope"}}""");
        Assert.Null(ReaderFor(path).TryLoad());
    }

    [Fact]
    public void GarbageEnvelopeReturnsNull()
    {
        var path = WriteStore("""{"encryption": "safeStorage.v1", "data": "!!!not-base64!!!"}""");
        Assert.Null(ReaderFor(path).TryLoad());
    }

    [Fact]
    public void WrongEncryptionSchemeReturnsNull()
    {
        var path = WriteStore("""{"encryption": "aes-gcm.v9", "data": "AAAA"}""");
        // Scheme is not ours, but the payload is not DPAPI-decryptable either: still null, never throws.
        Assert.Null(ReaderFor(path).TryLoad());
    }

    [Fact]
    public void DpapiEnvelopeRoundTripsOnWindows()
    {
        if (!OperatingSystem.IsWindows())
        {
            return; // DPAPI only exists on Windows.
        }

        var payload = """{"origin": "https://www.kimi.ai", "tokens": {"access_token": "dpapi-token"}}""";
        var blob = ProtectedData.Protect(Encoding.UTF8.GetBytes(payload), null, DataProtectionScope.CurrentUser);
        var path = WriteStore($"{{\"encryption\": \"safeStorage.v1\", \"data\": \"{Convert.ToBase64String(blob)}\"}}");

        var credential = ReaderFor(path).TryLoad();
        Assert.NotNull(credential);
        Assert.Equal("dpapi-token", credential!.Token);
        Assert.Equal("https://www.kimi.ai", credential.Origin);
    }

    [Fact]
    public void UndecryptableEnvelopeReturnsNull()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        // Valid base64, valid DPAPI shape for *another* scope — decrypt fails silently.
        var blob = ProtectedData.Protect("not-json"u8.ToArray(), null, DataProtectionScope.CurrentUser);
        var path = WriteStore($"{{\"encryption\": \"safeStorage.v1\", \"data\": \"{Convert.ToBase64String(blob)}\"}}");
        Assert.Null(ReaderFor(path).TryLoad());
    }

    [Fact]
    public void WindowsStoreIsTriedBeforeMacStore()
    {
        Directory.CreateDirectory(_dir);
        var windows = Path.Combine(_dir, "windows.json");
        var mac = Path.Combine(_dir, "mac.json");
        File.WriteAllText(windows, """{"tokens": {"access_token": "from-windows"}}""");
        File.WriteAllText(mac, """{"tokens": {"access_token": "from-mac"}}""");

        var reader = new KimiDesktopSessionReader(windowsStorePath: windows, macStorePath: mac);
        Assert.Equal("from-windows", reader.TryLoad()!.Token);
    }

    public void Dispose()
    {
        try
        {
            Directory.Delete(_dir, recursive: true);
        }
        catch (IOException)
        {
        }
    }
}
