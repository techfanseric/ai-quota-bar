using AQB.Core;
using Xunit;

namespace AQB.Providers.Kimi.Tests;

public class AnsiTextTests
{
    [Fact]
    public void StripsCsiOscAndControlSequences()
    {
        var noisy = "\u001b[32m5h limit\u001b[0m \u001b]8;;https://kimi.dev\u000789%\u001b]8;;\u0007 used, resets in 1h\u0000";
        var cleaned = AnsiText.Strip(noisy);
        Assert.Equal("5h limit 89% used, resets in 1h", cleaned);
    }

    [Fact]
    public void StripsOscWithEscapeTerminator()
    {
        var noisy = "\u001b]0;kimi\u001b\\Weekly limit 5% left";
        Assert.Equal("Weekly limit 5% left", AnsiText.Strip(noisy));
    }

    [Fact]
    public void EmptyInputStaysEmpty()
    {
        Assert.Equal("", AnsiText.Strip(""));
    }
}

public class KimiCliStatusParserTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 17, 8, 0, 0, TimeSpan.Zero);

    [Fact]
    public void ParsesUsedPercentAndResetDelta()
    {
        var output = """
            Kimi Code v1
              5h limit   45% used, resets in 2h
              Weekly limit 89% used, resets in 1d 18h 35m
            """;

        var snapshot = KimiCliStatusParser.Parse(output, Now);

        Assert.NotNull(snapshot.Secondary);
        Assert.NotNull(snapshot.Primary);
        Assert.Equal(45, snapshot.Secondary!.UsedPercent);
        Assert.Equal(Now.AddHours(2), snapshot.Secondary.ResetsAtUtc);
        Assert.Equal(89, snapshot.Primary!.UsedPercent);
        Assert.Equal(11, snapshot.Primary.RemainingPercent);
        Assert.Equal(Now.AddSeconds(86400 + 18 * 3600 + 35 * 60), snapshot.Primary.ResetsAtUtc);
        Assert.Equal(Now, snapshot.UpdatedAt);
    }

    [Fact]
    public void ParsesLeftAndRemainingFormsAsUsed()
    {
        var snapshot = KimiCliStatusParser.Parse(
            "5h limit: 11% left\nWeekly limit: 100% remaining\n", Now);

        Assert.Equal(89, snapshot.Secondary!.UsedPercent);
        Assert.Equal(0, snapshot.Primary!.UsedPercent);
        Assert.Equal(100, snapshot.Primary.RemainingPercent);
    }

    [Theory]
    [InlineData("250% used", 100)]
    [InlineData("0% used", 0)]
    [InlineData("150% left", 0)] // 100 - 150 clamped
    public void ClampsPercentToZeroToOneHundred(string fragment, double expectedUsed)
    {
        var snapshot = KimiCliStatusParser.Parse("Weekly limit " + fragment + "\n", Now);
        Assert.Equal(expectedUsed, snapshot.Primary!.UsedPercent);
    }

    [Fact]
    public void ParsesHourUnitVariants()
    {
        var snapshot = KimiCliStatusParser.Parse("5-hour limit 30% used\nWeekly limit 60% used\n", Now);
        Assert.NotNull(snapshot.Secondary);
        Assert.Equal(30, snapshot.Secondary!.UsedPercent);
    }

    [Fact]
    public void ParsesThroughAnsiNoise()
    {
        var output = "\u001b[?25l\u001b[1m\u001b]8;;https://kimi.dev\u0007Weekly limit\u001b]8;;\u0007 42% used, resets in 30m\u001b[0m\r\n";
        var snapshot = KimiCliStatusParser.Parse(output, Now);
        Assert.Equal(42, snapshot.Primary!.UsedPercent);
        Assert.Equal(Now.AddMinutes(30), snapshot.Primary.ResetsAtUtc);
    }

    [Fact]
    public void OnlyWeeklyLineYieldsNoSecondary()
    {
        var snapshot = KimiCliStatusParser.Parse("Weekly limit 10% used\n", Now);
        Assert.Null(snapshot.Secondary);
        Assert.NotNull(snapshot.Primary);
    }

    [Fact]
    public void TrustPromptThrowsWorkspaceTrustRequired()
    {
        var e = Assert.Throws<KimiCliException>(
            () => KimiCliStatusParser.Parse("Trust this folder? > No / Yes", Now));
        Assert.Equal(KimiCliReason.WorkspaceTrustRequired, e.Reason);
    }

    [Fact]
    public void MissingWindowsThrowsStatusUnavailable()
    {
        var e = Assert.Throws<KimiCliException>(() => KimiCliStatusParser.Parse("kimi code ready.\ncontext: 0 tokens\n", Now));
        Assert.Equal(KimiCliReason.StatusUnavailable, e.Reason);
    }

    [Fact]
    public void ToProviderSnapshotMapsWindowNamesAndRoles()
    {
        var snapshot = KimiCliStatusParser.Parse("5h limit 20% used\nWeekly limit 50% used\n", Now);
        var provider = snapshot.ToProviderSnapshot();

        Assert.Equal(ProviderKind.Kimi, provider.Kind);
        Assert.Equal(ProviderStatus.Ok, provider.Status);
        var account = Assert.Single(provider.Accounts);
        Assert.Equal("Kimi", account.Label);
        Assert.Equal("Kimi Code CLI /status", account.SourceLabel);
        Assert.Equal(2, account.Windows.Count);
        Assert.Equal("5h", account.Windows[0].Name);
        Assert.Equal(QuotaWindowRole.Secondary, account.Windows[0].Role);
        Assert.Equal(18000, account.Windows[0].WindowSeconds);
        Assert.Equal("Weekly", account.Windows[1].Name);
        Assert.Equal(QuotaWindowRole.Primary, account.Windows[1].Role);
        Assert.Equal(604800, account.Windows[1].WindowSeconds);
        Assert.Equal(Now, provider.LastUpdatedUtc);
    }
}

public class KimiCliLocatorTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "aqb-kimi-locator-" + Guid.NewGuid().ToString("N"));

    private string Dir(string name)
    {
        var dir = Path.Combine(_root, name);
        Directory.CreateDirectory(dir);
        return dir;
    }

    [Fact]
    public void FindsKimiUnderKimiCodeHomeBin()
    {
        var bin = Path.Combine(Dir("home"), "bin");
        Directory.CreateDirectory(bin);
        var exe = Path.Combine(bin, "kimi.cmd");
        File.WriteAllText(exe, "");

        var found = KimiCliLocator.Locate(env => env == "KIMI_CODE_HOME" ? Path.GetDirectoryName(bin) : null);
        Assert.Equal(exe, found);
    }

    [Fact]
    public void FindsKimiOnPath()
    {
        var dir = Dir("onpath");
        var exe = Path.Combine(dir, "kimi.exe");
        File.WriteAllText(exe, "");

        var found = KimiCliLocator.Locate(env => env == "PATH" ? dir : null);
        Assert.Equal(exe, found);
    }

    [Fact]
    public void ReturnsNullWhenNotInstalled()
    {
        Assert.Null(KimiCliLocator.Locate(env => null));
    }

    public void Dispose()
    {
        try
        {
            Directory.Delete(_root, recursive: true);
        }
        catch (IOException)
        {
        }
    }
}
