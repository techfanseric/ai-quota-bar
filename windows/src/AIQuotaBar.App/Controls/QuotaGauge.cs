// Swift 来源：无（Windows 端新增；provider 节头部环形图 —— 60px Donut，WPF 自绘）。
// 自绘路线：FrameworkElement.OnRender + DrawingContext（Arc 用 StreamGeometry.ArcTo，
// 等价于 Path+StreamGeometry；零第三方依赖）。禁 System.Drawing（那是托盘环 GDI+ 的地盘）。
// 视觉参数集中在主题字典：GaugeStrokeThickness（sys:Double），
// 本类常量仅为资源缺失时的兜底；分档色 QuotaTier（与托盘环同规则）。
// 主题切换：不自行订阅（避免每次 Rebuild 泄漏订阅），由宿主面板（QuotaPanel 单例）
// 在 ThemeChanged 时整体 Rebuild。

using System.Globalization;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;
using Brush = System.Windows.Media.Brush;
using Brushes = System.Windows.Media.Brushes;

namespace AIQuotaBar.App.Controls;

/// <summary>
/// 配额环形图：外圈轨道（ChartTrackBrush）+ 剩余百分比弧（分档色，圆头端帽），
/// 中心百分比文字。Percent 为 null 时只画灰轨道（无数据，对齐托盘环灰环语义）。
/// </summary>
public sealed class QuotaGauge : FrameworkElement
{
    private const double DefaultSize = 60;
    private const double DefaultStrokeThickness = 6;
    private const double CenterLabelFontSize = 12;

    // FrameworkElement 不带 FontFamily（那是 Control/TextElement 的属性）；AddOwner
    // TextElement.FontFamilyProperty（Inherits 元数据）让中心文字跟随宿主面板字体。
    public static readonly DependencyProperty FontFamilyProperty =
        TextElement.FontFamilyProperty.AddOwner(typeof(QuotaGauge));

    public System.Windows.Media.FontFamily FontFamily
    {
        get => (System.Windows.Media.FontFamily)GetValue(FontFamilyProperty);
        set => SetValue(FontFamilyProperty, value);
    }

    private double? _percent;

    /// <summary>剩余百分比（0-100）；null = 无数据（仅灰轨道）。</summary>
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
        var size = Math.Min(RenderSize.Width, RenderSize.Height);
        if (size <= 0)
        {
            return;
        }

        var stroke = Math.Min(ResolveMetric("GaugeStrokeThickness", DefaultStrokeThickness), size / 3);
        var radius = (size - stroke) / 2;
        var center = new Point(RenderSize.Width / 2, RenderSize.Height / 2);

        // 轨道整环。
        var trackBrush = TryFindResource("ChartTrackBrush") as Brush ?? Brushes.Gray;
        var trackPen = new Pen(trackBrush, stroke);
        trackPen.Freeze();
        drawingContext.DrawEllipse(null, trackPen, center, radius, radius);

        // 剩余弧（满环直接整圆描边，避免圆头端帽在 360° 处咬合出缺口）。
        if (Percent is { } percent && percent > 0)
        {
            var arcBrush = QuotaTier.ResolveBrush(this, percent);
            var arcPen = new Pen(arcBrush, stroke)
            {
                StartLineCap = PenLineCap.Round,
                EndLineCap = PenLineCap.Round,
            };
            arcPen.Freeze();
            if (percent >= 100)
            {
                drawingContext.DrawEllipse(null, arcPen, center, radius, radius);
            }
            else
            {
                var sweep = Math.Clamp(percent, 0, 100) / 100 * 360;
                drawingContext.DrawGeometry(null, arcPen, ArcGeometry(center, radius, -90, sweep));
            }

            DrawCenterLabel(drawingContext, center, percent);
        }
    }

    private void DrawCenterLabel(DrawingContext drawingContext, Point center, double percent)
    {
        var typeface = new Typeface(
            FontFamily ?? SystemFonts.MessageFontFamily,
            FontStyles.Normal,
            FontWeights.SemiBold,
            FontStretches.Normal);
        var text = new FormattedText(
            $"{Math.Round(percent):F0}%",
            CultureInfo.CurrentCulture,
            FlowDirection,
            typeface,
            CenterLabelFontSize,
            QuotaTier.ResolveBrush(this, percent),
            VisualTreeHelper.GetDpi(this).PixelsPerDip);
        drawingContext.DrawText(text, new Point(center.X - text.Width / 2, center.Y - text.Height / 2));
    }

    /// <summary>圆弧几何（StreamGeometry + ArcTo；顺时针，WPF y 轴向下故角度增即视觉顺时针）。</summary>
    private static StreamGeometry ArcGeometry(Point center, double radius, double startAngle, double sweepAngle)
    {
        var geometry = new StreamGeometry();
        using (var context = geometry.Open())
        {
            context.BeginFigure(PointOnCircle(center, radius, startAngle), isFilled: false, isClosed: false);
            context.ArcTo(
                PointOnCircle(center, radius, startAngle + sweepAngle),
                new Size(radius, radius),
                rotationAngle: 0,
                isLargeArc: sweepAngle > 180,
                SweepDirection.Clockwise,
                isStroked: true,
                isSmoothJoin: false);
        }

        geometry.Freeze();
        return geometry;
    }

    private static Point PointOnCircle(Point center, double radius, double degrees)
    {
        var radians = degrees * Math.PI / 180;
        return new Point(center.X + radius * Math.Cos(radians), center.Y + radius * Math.Sin(radians));
    }

    private double ResolveMetric(string key, double fallback) =>
        TryFindResource(key) is double value && value > 0 ? value : fallback;
}
