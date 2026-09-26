// Swift 来源：无（Windows 端新增；配额图表共用分档规则）。
// 分档与托盘环 RingIconFactory 严格一致（>50 绿 / >20 黄 / 其余红）；
// 本类只做「剩余百分比 → 主题画刷键」的映射与解析，色值本体在
// Panels/Themes/{Light,Dark}.xaml 的 AccentGreen/AccentYellow/AccentRed，
// 保证托盘环、面板环形图、模型行进度条三处分档永不漂移。

using System.Windows;
using Brush = System.Windows.Media.Brush;
using Brushes = System.Windows.Media.Brushes;

namespace AIQuotaBar.App.Controls;

/// <summary>配额剩余分档（呈现层专用；不进 Core——Swift 端同规则散落在渲染器内）。</summary>
public static class QuotaTier
{
    /// <summary>剩余百分比 → 分档画刷（资源缺失时回退系统色，仅防御性兜底）。</summary>
    public static Brush ResolveBrush(FrameworkElement element, double remainingPercent) =>
        remainingPercent switch
        {
            > 50 => Resolve(element, "AccentGreen", Brushes.Green),
            > 20 => Resolve(element, "AccentYellow", Brushes.Orange),
            _ => Resolve(element, "AccentRed", Brushes.Red),
        };

    private static Brush Resolve(FrameworkElement element, string key, Brush fallback) =>
        element.TryFindResource(key) as Brush ?? fallback;
}
