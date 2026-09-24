// Swift 来源：无（Windows 端新增；对应计划 §4 平台映射：IOKit.ps 电池状态 → GetSystemPowerStatus）
// 用途（计划 §5.1）：合盖场景的一次性引导与任务期安全线判断需电池电量与电源状态。

#nullable enable

namespace AIQuotaBar.Platform.Power;

/// <summary>
/// 一次 <c>GetSystemPowerStatus</c> 读取的系统电源快照（不可变 DTO）。
/// </summary>
/// <param name="AcStatus">外接电源状态。</param>
/// <param name="HasBattery">系统是否有电池（BatteryFlag 不含「无电池/未知」）。</param>
/// <param name="IsCharging">电池是否在充电（BatteryFlag 含 Charging 位）。</param>
/// <param name="IsBatterySaverOn">节电模式是否开启（SystemStatusFlag = 1）。</param>
/// <param name="BatteryLifePercent">剩余电量百分比（0–100）；设备无电池或不可知时为 <see langword="null"/>（原生 255）。</param>
public sealed record SystemPowerStatus(
    PowerAcStatus AcStatus,
    bool HasBattery,
    bool IsCharging,
    bool IsBatterySaverOn,
    byte? BatteryLifePercent);
