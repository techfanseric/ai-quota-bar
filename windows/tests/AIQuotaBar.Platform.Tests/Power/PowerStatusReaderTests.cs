// Swift 来源：无（Windows 端新增；对应计划 §4 平台映射：IOKit.ps 电池状态 → GetSystemPowerStatus）
// 被测类型：AIQuotaBar.Platform/Power/PowerStatusReader.cs
// 原则：CI runner 的真实电源形态不可控（虚拟机多无电池），只断言映射不变量，不断言具体电源状态。

using System;
using AIQuotaBar.Platform.Power;
using Xunit;

namespace AIQuotaBar.Platform.Tests.Power;

[Trait("Category", "RequiresWindows")]
public sealed class PowerStatusReaderTests
{
    [Fact]
    public void Read_ReturnsWithoutError_AndPercentInRangeOrNull()
    {
        var status = new PowerStatusReader().Read();

        // 应然：百分比要么 null（无电池/未知），要么落在 0..100（实然：越界即映射错误）。
        Assert.True(
            status.BatteryLifePercent is null ||
            (status.BatteryLifePercent >= 0 && status.BatteryLifePercent <= 100),
            $"BatteryLifePercent 应为 null 或 0..100（实然：{status.BatteryLifePercent}）。");

        // AC 状态必须是声明的枚举值（原生 0/1/255 之外的字节不应被捏造映射）。
        Assert.True(
            Enum.IsDefined(typeof(PowerAcStatus), status.AcStatus),
            $"AcStatus 应为已定义枚举值（实然：{status.AcStatus}）。");
    }
}
