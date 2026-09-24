// Swift 来源：AIQuotaBar/Services/Clash/ClashModels.swift — enum ClashRouteSwitchTimeFormat（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashRouteSwitchHistoryStoreTests.swift — testRecentSwitchesUseRelativeMinutesForFirstHour
//
// 说明：Swift 测试只钉 < 1 小时的相对文案（now / Nm ago / N 分钟前），此处逐字对齐。
// > 1 小时的同日/跨日分支依赖 Foundation 的本地化 formatted 输出，Windows 端以
// CurrentCulture 短时间与 "MM/dd HH:mm" 近似实现（行为差异待 UI 层接手时统一）。

#nullable enable

using System.Globalization;

namespace AIQuotaBar.Providers.Clash;

/// <summary>最近切换记录的时间文案：1 分钟内「刚刚」、1 小时内「N 分钟前」，其后当天取时刻、跨天取月日+时刻。</summary>
public static class ClashRouteSwitchTimeFormat
{
    public static string Text(DateTimeOffset date, DateTimeOffset relativeTo, AppLanguage language)
    {
        var elapsed = Math.Max(0, (relativeTo - date).TotalSeconds);
        if (elapsed < 60)
        {
            return language == AppLanguage.English ? "now" : "刚刚";
        }

        if (elapsed < 3_600)
        {
            var minutes = Math.Max(1, (int)(elapsed / 60));
            return language == AppLanguage.English ? $"{minutes}m ago" : $"{minutes} 分钟前";
        }

        var localDate = date.ToLocalTime();
        var localNow = relativeTo.ToLocalTime();
        if (localDate.Date == localNow.Date)
        {
            return localDate.ToString("t", CultureInfo.CurrentCulture);
        }

        return localDate.ToString("MM/dd HH:mm", CultureInfo.InvariantCulture);
    }
}
