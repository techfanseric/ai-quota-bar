using Xunit;

namespace AQB.Power.Tests;

public sealed class NativePowerRequestSmokeTests
{
    [Fact]
    public void PowerRequestApi_ReturnsValidHandle_ThenReleases()
    {
        // Real OS call: acquire once via the Power Request API, verify the handle,
        // then release. Runs on the Windows test machine only.
        using var request = new NativePowerRequest();

        request.Acquire(keepDisplayAwake: true);

        Assert.True(request.IsHolding);
        Assert.True(
            request.IsUsingPowerRequestApi,
            "PowerCreateRequest should succeed in an interactive Windows session");
        Assert.NotEqual(IntPtr.Zero, request.LastPowerRequestHandle);

        request.Release();

        Assert.False(request.IsHolding);
    }

    [Fact]
    public void NativePowerState_ReadsPlausibleValues()
    {
        var snapshot = new NativePowerState().Read();

        if (snapshot.HasBattery && snapshot.BatteryPercent is { } percent)
        {
            Assert.InRange(percent, 0, 100);
        }
    }
}
