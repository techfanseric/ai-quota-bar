// Swift 来源：无（Windows 端新增；对应计划 §4 平台映射：IOKit.ps 电池状态 → GetSystemPowerStatus）
// 值域按 winbase.h SYSTEM_POWER_STATUS.ACLineStatus：0=Offline，1=Online，255=Unknown。

#nullable enable

namespace AIQuotaBar.Platform.Power;

/// <summary>外接电源状态（SYSTEM_POWER_STATUS.ACLineStatus 的强类型化）。</summary>
public enum PowerAcStatus : byte
{
    /// <summary>使用电池供电（ACLineStatus = 0）。</summary>
    Offline = 0,

    /// <summary>接通外接电源（ACLineStatus = 1）。</summary>
    Online = 1,

    /// <summary>状态未知（ACLineStatus = 255）。</summary>
    Unknown = 255,
}
