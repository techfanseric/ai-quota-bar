using Xunit;

namespace AQB.Power.Tests;

public sealed class SleepProtectionControllerTests
{
    private static (SleepProtectionController Controller, FakePowerRequest Request, FakePowerState Power, MutableClock Clock) Create(
        TimeSpan? grace = null, TimeSpan? maxHold = null)
    {
        var request = new FakePowerRequest();
        var power = new FakePowerState();
        var clock = new MutableClock();
        var controller = new SleepProtectionController(
            request, power, clock,
            gracePeriod: grace, maxHoldDuration: maxHold,
            evaluationInterval: TimeSpan.Zero); // fully manual evaluation
        return (controller, request, power, clock);
    }

    [Fact]
    public void BeginTask_HoldsSystemAndDisplay_AndReportsActive()
    {
        var (controller, request, _, _) = Create();

        controller.BeginTask("turn-1", "codex");

        Assert.Equal(ProtectionStatus.Active, controller.Snapshot.Status);
        Assert.Equal("active", controller.Snapshot.StatusText);
        Assert.Equal(1, controller.Snapshot.ActiveTaskCount);
        Assert.Equal(new[] { "codex" }, controller.Snapshot.ActiveProviders);
        Assert.True(controller.Snapshot.KeepDisplayAwake);
        Assert.True(controller.Snapshot.KeepDisplayAwakeEffective);
        Assert.True(request.SystemHeld);
        Assert.True(request.DisplayRequired);
    }

    [Fact]
    public void MultipleTasks_AreCounted_UntilTheLastOneEnds()
    {
        var (controller, request, _, _) = Create();

        controller.BeginTask("a", "codex");
        controller.BeginTask("b", "kimi");
        controller.BeginTask("c", "codex");

        Assert.Equal(3, controller.Snapshot.ActiveTaskCount);
        Assert.Equal(new[] { "codex", "kimi" }, controller.Snapshot.ActiveProviders);

        controller.EndTask("a", "codex");
        controller.EndTask("b", "kimi");
        Assert.Equal(ProtectionStatus.Active, controller.Snapshot.Status);
        Assert.True(request.SystemHeld);

        controller.EndTask("c", "codex");
        Assert.Equal(0, controller.Snapshot.ActiveTaskCount);
        Assert.Empty(controller.Snapshot.ActiveProviders);
    }

    [Fact]
    public void BeginTask_ForKnownTask_RefreshesActivityWithoutDoubleCounting()
    {
        var (controller, _, _, clock) = Create();

        controller.BeginTask("a", "codex");
        clock.Advance(TimeSpan.FromMinutes(2));
        controller.BeginTask("a", "codex");

        Assert.Equal(1, controller.Snapshot.ActiveTaskCount);
        Assert.True(controller.HasFreshActivity);
    }

    [Fact]
    public void GracePeriod_299Seconds_StillHolds_300Seconds_Releases()
    {
        var (controller, request, _, clock) = Create(grace: TimeSpan.FromSeconds(300));

        controller.BeginTask("a", "codex");
        controller.EndTask("a", "codex");
        Assert.Equal(ProtectionStatus.Grace, controller.Snapshot.Status);
        Assert.True(request.SystemHeld);

        clock.Advance(TimeSpan.FromSeconds(299));
        controller.Evaluate();
        Assert.Equal(ProtectionStatus.Grace, controller.Snapshot.Status);
        Assert.True(request.SystemHeld);

        clock.Advance(TimeSpan.FromSeconds(1));
        controller.Evaluate();
        Assert.Equal(ProtectionStatus.Released, controller.Snapshot.Status);
        Assert.False(request.SystemHeld);
        Assert.Equal("released", controller.Snapshot.StatusText);
    }

    [Fact]
    public void NewTaskWithinGrace_CancelsPendingRelease()
    {
        var (controller, request, _, clock) = Create(grace: TimeSpan.FromSeconds(300));

        controller.BeginTask("a", "codex");
        controller.EndTask("a", "codex");

        clock.Advance(TimeSpan.FromSeconds(100));
        controller.BeginTask("b", "codex");
        Assert.Equal(ProtectionStatus.Active, controller.Snapshot.Status);
        Assert.True(request.SystemHeld);

        // The grace timer restarted around the new task's eventual end.
        controller.EndTask("b", "codex");
        clock.Advance(TimeSpan.FromSeconds(299));
        controller.Evaluate();
        Assert.Equal(ProtectionStatus.Grace, controller.Snapshot.Status);

        clock.Advance(TimeSpan.FromSeconds(1));
        controller.Evaluate();
        Assert.Equal(ProtectionStatus.Released, controller.Snapshot.Status);
    }

    [Fact]
    public void Disable_ReleasesImmediately_EvenWithActiveTasks_CountingContinues()
    {
        var (controller, request, _, _) = Create();

        controller.BeginTask("a", "codex");
        controller.Disable();

        Assert.False(controller.IsEnabled);
        Assert.False(request.SystemHeld);
        Assert.Equal(ProtectionStatus.Released, controller.Snapshot.Status);
        // Counting stays authoritative while protection is off (macOS parity).
        Assert.Equal(1, controller.Snapshot.ActiveTaskCount);

        controller.Enable();
        Assert.Equal(ProtectionStatus.Active, controller.Snapshot.Status);
        Assert.True(request.SystemHeld);
    }

    [Fact]
    public void Battery19PercentOnBattery_DropsDisplay_KeepsSystem()
    {
        var (controller, request, power, _) = Create();
        power.Snapshot = new PowerStatusSnapshot(BatteryPercent: 19, HasBattery: true, OnAcPower: false);

        controller.BeginTask("a", "codex");

        Assert.True(request.SystemHeld);
        Assert.False(request.DisplayRequired);
        Assert.True(controller.Snapshot.KeepDisplayAwake);
        Assert.False(controller.Snapshot.KeepDisplayAwakeEffective);
        Assert.Equal(ProtectionStatus.Active, controller.Snapshot.Status);
    }

    [Theory]
    [InlineData(20, false)]   // exactly 20% -> allowed (strictly below 20 degrades)
    [InlineData(5, true)]     // any percentage on AC -> allowed
    public void BatteryBoundaries_KeepDisplay(int percent, bool onAc)
    {
        var (controller, request, power, _) = Create();
        power.Snapshot = new PowerStatusSnapshot(percent, HasBattery: true, OnAcPower: onAc);

        controller.BeginTask("a", "codex");

        Assert.True(request.SystemHeld);
        Assert.True(request.DisplayRequired);
        Assert.True(controller.Snapshot.KeepDisplayAwakeEffective);
    }

    [Fact]
    public void DesktopWithoutBattery_KeepsDisplay()
    {
        var (controller, request, power, _) = Create();
        power.Snapshot = new PowerStatusSnapshot(BatteryPercent: null, HasBattery: false, OnAcPower: false);

        controller.BeginTask("a", "codex");

        Assert.True(request.DisplayRequired);
    }

    [Fact]
    public void BatteryRecovers_DisplayProtectionReturns()
    {
        var (controller, request, power, _) = Create();
        power.Snapshot = new PowerStatusSnapshot(10, HasBattery: true, OnAcPower: false);
        controller.BeginTask("a", "codex");
        Assert.False(request.DisplayRequired);

        power.Snapshot = new PowerStatusSnapshot(80, HasBattery: true, OnAcPower: false);
        controller.Evaluate();

        Assert.True(request.DisplayRequired);
        Assert.True(controller.Snapshot.KeepDisplayAwakeEffective);
    }

    [Fact]
    public void MaxHold_43199Seconds_KeepsHolding_43200Seconds_Suspends()
    {
        var (controller, request, _, clock) = Create(maxHold: TimeSpan.FromSeconds(43200));

        controller.BeginTask("a", "codex");
        clock.Advance(TimeSpan.FromSeconds(43199));
        controller.Evaluate();

        Assert.Equal(ProtectionStatus.Active, controller.Snapshot.Status);
        Assert.True(request.SystemHeld);

        clock.Advance(TimeSpan.FromSeconds(1));
        controller.Evaluate();

        Assert.Equal(ProtectionStatus.Suspended, controller.Snapshot.Status);
        Assert.Equal("maximumDuration", controller.Snapshot.SuspendedReason);
        Assert.False(request.SystemHeld);
        Assert.Equal(1, controller.Snapshot.ActiveTaskCount);
    }

    [Fact]
    public void MaxHoldSuspension_IsPerBatch_NewTasksGetFreshWindow()
    {
        var (controller, request, _, clock) = Create(maxHold: TimeSpan.FromSeconds(43200));

        controller.BeginTask("a", "codex");
        clock.Advance(TimeSpan.FromSeconds(43200));
        controller.Evaluate();
        Assert.Equal(ProtectionStatus.Suspended, controller.Snapshot.Status);

        // Still suspended while the same task keeps running.
        clock.Advance(TimeSpan.FromSeconds(1));
        controller.Evaluate();
        Assert.Equal(ProtectionStatus.Suspended, controller.Snapshot.Status);

        // Count back to zero resets the suspension.
        controller.EndTask("a", "codex");
        Assert.Equal(ProtectionStatus.Released, controller.Snapshot.Status);

        controller.BeginTask("b", "codex");
        Assert.Equal(ProtectionStatus.Active, controller.Snapshot.Status);
        Assert.True(request.SystemHeld);

        clock.Advance(TimeSpan.FromSeconds(43199));
        controller.Evaluate();
        Assert.Equal(ProtectionStatus.Active, controller.Snapshot.Status);

        clock.Advance(TimeSpan.FromSeconds(1));
        controller.Evaluate();
        Assert.Equal(ProtectionStatus.Suspended, controller.Snapshot.Status);
    }

    [Fact]
    public void TaskCount_IsCappedAt99ForReporting()
    {
        var (controller, _, _, _) = Create();

        for (var i = 0; i < 150; i++)
        {
            controller.BeginTask("task-" + i, "codex");
        }

        Assert.Equal(99, controller.Snapshot.ActiveTaskCount);
    }

    [Fact]
    public void Dispose_ReleasesEvenWhenNothingWasHeld()
    {
        var (controller, request, _, _) = Create();

        controller.Dispose();

        Assert.True(request.ReleaseCount >= 1);
        Assert.Equal(ProtectionStatus.Released, controller.Snapshot.Status);
    }

    [Fact]
    public void StatusChanged_FiresOnSnapshotChanges_ButNotForNoOps()
    {
        var (controller, _, _, _) = Create();
        var seen = new List<(ProtectionStatus Status, int Count)>();
        controller.StatusChanged += (_, snapshot) => seen.Add((snapshot.Status, snapshot.ActiveTaskCount));

        controller.BeginTask("a", "codex");   // active, 1
        controller.BeginTask("b", "codex");   // active, 2 (count changed -> event)
        controller.EndTask("b", "codex");     // active, 1
        controller.Evaluate();                // no snapshot change -> no event
        controller.EndTask("a", "codex");     // grace
        controller.Dispose();                 // released

        Assert.Equal(
            new[]
            {
                (ProtectionStatus.Active, 1),
                (ProtectionStatus.Active, 2),
                (ProtectionStatus.Active, 1),
                (ProtectionStatus.Grace, 0),
                (ProtectionStatus.Released, 0),
            },
            seen);
    }
}
