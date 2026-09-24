// Swift 来源：AIQuotaBar/Services/Clash/ClashAPIClient.swift — enum ClashRouteSorter（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashRouteResolverTests.swift — testSorterPlacesSuccessfulLowestLatencyFirstAndTimeoutsLast

#nullable enable

using System.Collections.Generic;
using System.Globalization;

namespace AIQuotaBar.Providers.Clash;

/// <summary>线路排序：可用延迟在前且升序（快→慢），超时(0)与未测(null)在后，其余按名称比较器兜底。</summary>
public static class ClashRouteSorter
{
    public static IReadOnlyList<ClashRoute> Sorted(IReadOnlyList<ClashRoute> routes)
    {
        var sorted = new List<ClashRoute>(routes);
        sorted.Sort((lhs, rhs) =>
        {
            if (lhs.HasUsableDelay && !rhs.HasUsableDelay)
            {
                return -1;
            }

            if (!lhs.HasUsableDelay && rhs.HasUsableDelay)
            {
                return 1;
            }

            if (lhs.HasUsableDelay &&
                rhs.HasUsableDelay &&
                lhs.Delay != rhs.Delay)
            {
                return lhs.Delay!.Value.CompareTo(rhs.Delay!.Value);
            }

            // localizedStandardCompare 的 Windows 近似（Swift 端 Finder 式本地化排序）。
            return string.Compare(lhs.Name, rhs.Name, CultureInfo.CurrentCulture, CompareOptions.OrdinalIgnoreCase);
        });
        return sorted;
    }
}
