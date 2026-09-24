// Swift 来源：无（Windows 端新增；对应计划 §4 平台映射：IOKit.ps 电池状态 → kernel32 GetSystemPowerStatus）
// 对应测试：windows/tests/AIQuotaBar.Platform.Tests/Power/PowerStatusReaderTests.cs
//
// P/Invoke 依据（Microsoft Learn，winbase.h）：
// BOOL GetSystemPowerStatus(LPSYSTEM_POWER_STATUS lpSystemPowerStatus)（kernel32.dll）。
// SYSTEM_POWER_STATUS 字段顺序：BYTE ACLineStatus; BYTE BatteryFlag; BYTE BatteryLifePercent;
// BYTE SystemStatusFlag; DWORD BatteryLifeTime; DWORD BatteryFullLifeTime;（4 字节对齐，无填充缝隙）
// ACLineStatus：0=Offline / 1=Online / 255=Unknown；BatteryFlag 位：1=High、2=Low、4=Critical、
// 8=Charging、128=NoBattery、255=Unknown；BatteryLifePercent：0–100 或 255=Unknown；
// SystemStatusFlag：1=节电模式开启。

#nullable enable

using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace AIQuotaBar.Platform.Power;

/// <summary>
/// 系统电源状态读取器：GetSystemPowerStatus 的一次性快照封装。
/// </summary>
/// <remarks>
/// macOS 端对应物：IOKit <c>IOPSCopyPowerSourcesInfo</c> 轮询（计划 §4「IOKit.ps（电池）」行）。
/// Windows 侧为无通知的拉模型——上层按需调用 <see cref="Read"/> 或低频轮询。
/// </remarks>
public sealed class PowerStatusReader
{
    private const byte BatteryFlagCharging = 0x8;
    private const byte BatteryFlagNoBattery = 0x80;
    private const byte BatteryFlagUnknown = 0xFF;
    private const byte PercentUnknown = 255;

    /// <summary>读取当前系统电源快照。无电池/台式机也正常返回（HasBattery = false）。</summary>
    /// <exception cref="Win32Exception">GetSystemPowerStatus 返回 FALSE。</exception>
    public SystemPowerStatus Read()
    {
        var native = default(NativeMethods.SystemPowerStatus);
        if (!NativeMethods.GetSystemPowerStatus(ref native))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "GetSystemPowerStatus 失败。");
        }

        var acStatus = native.ACLineStatus switch
        {
            0 => PowerAcStatus.Offline,
            1 => PowerAcStatus.Online,
            _ => PowerAcStatus.Unknown,
        };

        // BatteryFlag=255（未知）或含 128（无系统电池）都视为无电池可依赖
        var hasBattery = native.BatteryFlag != BatteryFlagUnknown &&
            (native.BatteryFlag & BatteryFlagNoBattery) == 0;
        var isCharging = (native.BatteryFlag & BatteryFlagCharging) != 0;
        var isBatterySaverOn = native.SystemStatusFlag == 1;
        byte? batteryLifePercent = native.BatteryLifePercent == PercentUnknown
            ? null
            : native.BatteryLifePercent;

        return new SystemPowerStatus(
            acStatus,
            hasBattery,
            isCharging,
            isBatterySaverOn,
            batteryLifePercent);
    }

    /// <summary>kernel32 原生入口（签名按 winbase.h 逐字段核对）。</summary>
    private static class NativeMethods
    {
        [DllImport("kernel32.dll", EntryPoint = "GetSystemPowerStatus", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetSystemPowerStatus(ref SystemPowerStatus lpSystemPowerStatus);

        /// <summary>winbase.h SYSTEM_POWER_STATUS，字段顺序与原生严格一致。</summary>
        [StructLayout(LayoutKind.Sequential)]
        public struct SystemPowerStatus
        {
            public byte ACLineStatus;
            public byte BatteryFlag;
            public byte BatteryLifePercent;
            public byte SystemStatusFlag;   // 旧名 Reserved1；Win10 起为节电模式标志
            public uint BatteryLifeTime;
            public uint BatteryFullLifeTime;
        }
    }
}
