using AQB.Power;
using Xunit;

namespace AQB.Power.Tests;

public sealed class ClosedLidModeControllerTests : IDisposable
{
    private readonly string _markerPath = Path.Combine(Path.GetTempPath(), "aqb-lid-" + Guid.NewGuid().ToString("N") + ".json");

    private readonly FakeScheme _scheme = new();

    public void Dispose()
    {
        if (File.Exists(_markerPath))
        {
            File.Delete(_markerPath);
        }
    }

    [Fact]
    public void Acquire_WritesZeroAndRememberOriginals()
    {
        _scheme.Ac = 1;
        _scheme.Dc = 1;
        using var controller = new ClosedLidModeController(_scheme, _markerPath);
        Assert.True(controller.Acquire());
        Assert.Equal(ClosedLidStatus.Active, controller.Status);
        Assert.Equal((0, 0), (_scheme.Ac, _scheme.Dc));
        Assert.True(_scheme.Applied);
        Assert.True(File.Exists(_markerPath));
        Assert.Contains("\"lidActionAc\":1", File.ReadAllText(_markerPath));
        Assert.Contains("\"lidActionDc\":1", File.ReadAllText(_markerPath));
    }

    [Fact]
    public void Acquire_AlreadyZeroStillHoldsAndRestores()
    {
        _scheme.Ac = 0;
        _scheme.Dc = 3;
        using var controller = new ClosedLidModeController(_scheme, _markerPath);
        Assert.True(controller.Acquire());
        // No redundant write for AC (already 0), DC rewritten.
        Assert.Equal(0, _scheme.AcWriteCount);
        Assert.Equal(1, _scheme.DcWriteCount);
        controller.Restore();
        Assert.Equal((0, 3), (_scheme.Ac, _scheme.Dc));
    }

    [Fact]
    public void Restore_WritesExactOriginalsAndDeletesMarker()
    {
        _scheme.Ac = 2;
        _scheme.Dc = 1;
        var controller = new ClosedLidModeController(_scheme, _markerPath);
        Assert.True(controller.Acquire());
        Assert.True(controller.Restore());
        Assert.Equal(ClosedLidStatus.Restored, controller.Status);
        Assert.Equal((2, 1), (_scheme.Ac, _scheme.Dc));
        Assert.False(File.Exists(_markerPath));
        // Restoring again is a no-op.
        Assert.True(controller.Restore());
        controller.Dispose();
    }

    [Fact]
    public void Acquire_IdempotentWhileActive()
    {
        _scheme.Ac = 1;
        _scheme.Dc = 1;
        using var controller = new ClosedLidModeController(_scheme, _markerPath);
        Assert.True(controller.Acquire());
        var writes = _scheme.AcWriteCount + _scheme.DcWriteCount;
        Assert.True(controller.Acquire());
        Assert.Equal(writes, _scheme.AcWriteCount + _scheme.DcWriteCount);
    }

    [Fact]
    public void NonAdmin_ReportedWithoutWrites()
    {
        _scheme.Ac = 1;
        _scheme.Dc = 1;
        _scheme.Admin = false;
        using var controller = new ClosedLidModeController(_scheme, _markerPath);
        Assert.False(controller.Acquire());
        Assert.Equal(ClosedLidStatus.RequiresAdministrator, controller.Status);
        Assert.Equal((1, 1), (_scheme.Ac, _scheme.Dc));
        Assert.False(File.Exists(_markerPath));
    }

    [Fact]
    public void UnreadableLidAction_FailsCleanly()
    {
        _scheme.ReadFails = true;
        using var controller = new ClosedLidModeController(_scheme, _markerPath);
        Assert.False(controller.Acquire());
        Assert.Equal(ClosedLidStatus.Failed, controller.Status);
        Assert.NotNull(controller.FailureReason);
    }

    [Fact]
    public void DcWriteFailure_RollsBackAcWrite()
    {
        _scheme.Ac = 1;
        _scheme.Dc = 1;
        _scheme.FailDcWrite = true;
        using var controller = new ClosedLidModeController(_scheme, _markerPath);
        Assert.False(controller.Acquire());
        Assert.Equal(ClosedLidStatus.Failed, controller.Status);
        Assert.Equal(1, _scheme.Ac); // rolled back
        Assert.False(File.Exists(_markerPath));
    }

    [Fact]
    public void Dispose_RestoresFailSafe()
    {
        _scheme.Ac = 1;
        _scheme.Dc = 2;
        var controller = new ClosedLidModeController(_scheme, _markerPath);
        Assert.True(controller.Acquire());
        controller.Dispose();
        Assert.Equal((1, 2), (_scheme.Ac, _scheme.Dc));
        Assert.False(File.Exists(_markerPath));
    }

    [Fact]
    public void CrashSelfHeal_RestoresFromOrphanedMarker()
    {
        File.WriteAllText(_markerPath, "{\"version\":1,\"lidActionAc\":1,\"lidActionDc\":3}");
        _scheme.Ac = 0;
        _scheme.Dc = 0;
        using var controller = new ClosedLidModeController(_scheme, _markerPath);
        // The constructor healed the orphan: values restored and marker removed.
        Assert.Equal((1, 3), (_scheme.Ac, _scheme.Dc));
        Assert.False(File.Exists(_markerPath));
        Assert.Equal(ClosedLidStatus.Inactive, controller.Status);
    }

    [Fact]
    public void CrashSelfHeal_CorruptMarkerIsDeletedWithoutWrites()
    {
        File.WriteAllText(_markerPath, "{not json");
        using var controller = new ClosedLidModeController(_scheme, _markerPath);
        Assert.False(File.Exists(_markerPath));
        Assert.Equal(0, _scheme.AcWriteCount);
    }

    /// <summary>Real-machine smoke: reading LIDACTION via the Power* APIs (no writes, no admin needed).</summary>
    [Fact]
    public void ReadLidAction_RealSchemeSmoke()
    {
        using var scheme = new PowerCfgClosedLidScheme();
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        var ac = scheme.ReadLidAction(true);
        var dc = scheme.ReadLidAction(false);
        Assert.NotNull(ac);
        Assert.NotNull(dc);
        Assert.InRange(ac!.Value, 0, 3);
        Assert.InRange(dc!.Value, 0, 3);
    }

    private sealed class FakeScheme : IClosedLidPowerScheme
    {
        public int Ac { get; set; }

        public int Dc { get; set; }

        public bool Admin { get; set; } = true;

        public bool ReadFails { get; set; }

        public bool FailDcWrite { get; set; }

        public bool Applied { get; private set; }

        public int AcWriteCount { get; private set; }

        public int DcWriteCount { get; private set; }

        public bool IsAdministrator => Admin;

        public int? ReadLidAction(bool acPower) => ReadFails ? null : acPower ? Ac : Dc;

        public bool WriteLidAction(bool acPower, int value)
        {
            if (acPower)
            {
                Ac = value;
                AcWriteCount++;
                return true;
            }

            if (FailDcWrite)
            {
                return false;
            }

            Dc = value;
            DcWriteCount++;
            return true;
        }

        public bool Apply()
        {
            Applied = true;
            return true;
        }

        public void Dispose()
        {
        }
    }
}
