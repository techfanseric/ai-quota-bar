// Swift 来源：无（Windows 端新增；模型行线性进度条 —— 全宽 6px 圆角，WPF 自绘）。
// 呈现语义（对齐 Swift 端 progress bar 规则，见 UsageData.cs 契约注释）：
//  - 优先 ProgressBarPercentOverride（Codex credits 行：条 = 剩余比）；
//  - 其次 CurrentIntervalRemainingPercent（API 直给）；
//  - 否则 count 比例 CurrentIntervalRemaining/Total；
//  - 三者皆无（Total≤0 且无百分比）→ null：只画灰轨道，不误报 0% 红条。
// 条内不放文字；百分比文本由 QuotaPanel.BuildModelRow 原样保留在行右侧。
// 视觉参数：UsageBarHeight（主题字典 sys:Double，默认 6）；分档色 QuotaTier（同托盘环规则）。

using System.Windows;
using System.Windows.Media;
using AIQuotaBar.Core.Contracts;
using Brush = System.Windows.Media.Brush;
using Brushes = System.Windows.Media.Brushes;

namespace AIQuotaBar.App.Controls;

/// <summary>模型配额行进度条：圆角轨道 + 剩余百分比填充（分档色）。</summary>
public sealed class UsageBar : FrameworkElement
{
    private const double DefaultBarHeight = 6;

    private double? _percent;

    /// <summary>剩余百分比（0-100）；null = 无数据（仅轨道）。</summary>
    public double? Percent
    {
        get => _percent;
        set
        {
            _percent = value;
            InvalidateVisual();
        }
    }

    protected override void OnRender(DrawingContext drawingContext)
    {
        var height = RenderSize.Height;
        var width = RenderSize.Width;
        if (width <= 0 || height <= 0)
        {
            return;
        }

        var radius = height / 2;
        var track = new RectangleGeometry(new Rect(0, 0, width, height), radius, radius);
        track.Freeze();
        drawingContext.DrawGeometry(TryFindResource("ChartTrackBrush") as Brush ?? Brushes.Gray, null, track);

        if (Percent is not { } percent || percent <= 0)
        {
            return;
        }

        var fillWidth = Math.Clamp(percent, 0, 100) / 100 * width;
        var fillRadius = Math.Min(radius, fillWidth / 2); // 极小填充时收敛圆角，避免端帽出格
        var fill = new RectangleGeometry(new Rect(0, 0, fillWidth, height), fillRadius, fillRadius);
        fill.Freeze();
        drawingContext.DrawGeometry(QuotaTier.ResolveBrush(this, percent), null, fill);
    }

    /// <summary>按模型行契约解析剩余百分比（见文件头三条优先级；无据可依返回 null）。</summary>
    public static double? ResolvePercent(ModelUsageData model)
    {
        if (model.ProgressBarPercentOverride is { } overridePercent)
        {
            return Math.Clamp(overridePercent, 0, 100);
        }

        if (model.CurrentIntervalRemainingPercent is { } percent)
        {
            return Math.Clamp(percent, 0, 100);
        }

        return model.CurrentIntervalTotal > 0
            ? Math.Clamp(model.CurrentIntervalRemaining * 100.0 / model.CurrentIntervalTotal, 0, 100)
            : null;
    }

    /// <summary>构造器：模型行进度条（水平铺满；上边距 4 与行内文本拉开 8px 节奏）。</summary>
    public static UsageBar ForModel(ModelUsageData model) => new()
    {
        Percent = ResolvePercent(model),
        Height = ResolveBarHeight(),
        Margin = new Thickness(0, 4, 0, 0),
        HorizontalAlignment = HorizontalAlignment.Stretch,
    };

    /// <summary>包装 BuildModelRow 已产出的文本行 + 追加进度条（QuotaPanel 唯一接入点）。</summary>
    public static UIElement WrapModelRow(UIElement textRow, ModelUsageData model) => new StackPanel
    {
        Children =
        {
            textRow,
            ForModel(model),
        },
    };

    private static double ResolveBarHeight() =>
        Application.Current?.TryFindResource("UsageBarHeight") is double height && height > 0 ? height : DefaultBarHeight;
}
