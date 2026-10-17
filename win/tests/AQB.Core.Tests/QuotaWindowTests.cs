using AQB.Core;
using Xunit;

namespace AQB.Core.Tests;

public class QuotaWindowTests
{
    private static readonly DateTimeOffset Reset = new(2026, 10, 17, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void RemainingPercentIsRoundedAwayFromZero()
    {
        var window = new QuotaWindowSample { UsedPercent = 35.4, ResetsAtUtc = Reset, CapturedAtUtc = Reset.AddHours(-1), WindowSeconds = 18000 };
        Assert.Equal(65, window.RemainingPercent);

        var window2 = new QuotaWindowSample { UsedPercent = 35.5, ResetsAtUtc = Reset, CapturedAtUtc = Reset.AddHours(-1), WindowSeconds = 18000 };
        // 100 - 35.5 = 64.5 -> rounds away from zero to 65
        Assert.Equal(65, window2.RemainingPercent);
    }

    [Fact]
    public void WindowStartIsDerivedFromResetMinusWindowSeconds()
    {
        var window = new QuotaWindowSample { UsedPercent = 10, ResetsAtUtc = Reset, CapturedAtUtc = Reset.AddHours(-1), WindowSeconds = 604800 };
        Assert.Equal(Reset.AddSeconds(-604800), window.WindowStartUtc);
    }

    [Fact]
    public void ExplicitStartWinsOverDerived()
    {
        var explicitStart = Reset.AddDays(-30);
        var window = new QuotaWindowSample { UsedPercent = 10, ResetsAtUtc = Reset, CapturedAtUtc = Reset, StartsAtUtc = explicitStart };
        Assert.Equal(explicitStart, window.WindowStartUtc);
    }
}

public class TimeTextTests
{
    [Theory]
    [InlineData(0, "0m")]
    [InlineData(59, "0m")]
    [InlineData(60, "1m")]
    [InlineData(3599, "59m")]
    [InlineData(3600, "1.0h")]
    [InlineData(3.2 * 3600, "3.2h")]
    [InlineData(47.9 * 3600, "47.9h")]
    [InlineData(48 * 3600, "2.0d")]
    [InlineData(5 * 86400, "5.0d")]
    public void FormatRemainingCases(double seconds, string expected)
    {
        Assert.Equal(expected, TimeText.FormatRemaining(TimeSpan.FromSeconds(seconds)));
    }

    [Fact]
    public void FixedIsoAlwaysUtcWithMilliseconds()
    {
        var dto = new DateTimeOffset(2026, 10, 17, 8, 30, 5, 123, TimeSpan.FromHours(8));
        Assert.Equal("2026-10-17T00:30:05.123Z", TimeText.FixedIso(dto));
    }

    [Fact]
    public void RoundTripIso()
    {
        var text = "2026-10-17T00:30:05.123Z";
        Assert.True(TimeText.TryParseIso(text, out var parsed));
        Assert.Equal(TimeSpan.Zero, parsed.Offset);

        Assert.True(TimeText.TryParseIso("2026-10-17T00:30:05Z", out var parsed2));
        Assert.Equal(0, parsed2.Millisecond);
    }

    [Fact]
    public void MaskLabelMasksEmailLocalPart()
    {
        Assert.Equal("e***@example.com", TimeText.MaskLabel("eric@example.com"));
        Assert.Equal("a***@x.io", TimeText.MaskLabel("a@x.io"));
        Assert.Equal("u***@do main", TimeText.MaskLabel("username@do main"));
        Assert.Equal("", TimeText.MaskLabel(""));
    }
}

public class AccountFingerprintTests
{
    [Fact]
    public void CodexDigestIsStableLowercaseHex()
    {
        var digest = AccountFingerprint.Codex("org-test");
        Assert.Equal(64, digest.Length);
        Assert.Matches("^[0-9a-f]{64}$", digest);
        Assert.Equal(digest, AccountFingerprint.Codex("org-test"));
        Assert.NotEqual(digest, AccountFingerprint.Codex("org-other"));
    }

    [Fact]
    public void CodexDigestUsesCodexAccountPrefix()
    {
        // Locked to a known vector: SHA-256("codex-account|org-test")
        Assert.Equal("1754784ce02b971fc12503c849cd9d413e55f40454783f0963f98b3b3bf937e7", AccountFingerprint.Codex("org-test"));
    }

    [Fact]
    public void WatchEmailDigestTrimsAndLowercases()
    {
        Assert.Equal(AccountFingerprint.WatchEmail("ERIC@Example.com "), AccountFingerprint.WatchEmail("eric@example.com"));
    }
}
