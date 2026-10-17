namespace AQB.Power;

/// <summary>
/// Battery / AC status via GetSystemPowerStatus (chosen over
/// SystemInformation.PowerStatus so the project can stay on plain net8.0).
/// On non-Windows platforms or read failure it reports a battery-less desktop,
/// which disables the low-battery degrade rule.
/// </summary>
public sealed class NativePowerState : IPowerState
{
    private const byte AcOnline = 1;
    private const byte BatteryPercentUnknown = 255;
    private const byte BatteryFlagNoBattery = 0x80;
    private const byte BatteryFlagUnknown = 255;

    public PowerStatusSnapshot Read()
    {
        if (!OperatingSystem.IsWindows())
        {
            return new PowerStatusSnapshot(BatteryPercent: null, HasBattery: false, OnAcPower: false);
        }

        try
        {
            var status = new NativeMethods.SystemPowerStatus();
            if (!NativeMethods.GetSystemPowerStatus(ref status))
            {
                return new PowerStatusSnapshot(null, HasBattery: false, OnAcPower: false);
            }

            var hasBattery = status.BatteryFlag != BatteryFlagUnknown
                && (status.BatteryFlag & BatteryFlagNoBattery) == 0;
            int? percent = status.BatteryLifePercent switch
            {
                <= 100 => status.BatteryLifePercent,
                _ => null, // 255 / out-of-range = unknown
            };
            return new PowerStatusSnapshot(percent, hasBattery, status.AcLineStatus == AcOnline);
        }
        catch
        {
            return new PowerStatusSnapshot(null, HasBattery: false, OnAcPower: false);
        }
    }
}
