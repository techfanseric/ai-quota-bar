using AQB.Core;

namespace AQB.App;

/// <summary>Thin capsule progress bar (native flyout style): track + colored fill + threshold ticks.</summary>
internal sealed class CapsuleBar : Control
{
    private double _percent;

    public CapsuleBar()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        Height = 6;
    }

    public NativePalette Palette { get; set; } = NativePalette.System();

    public double Percent
    {
        get => _percent;
        set
        {
            _percent = Math.Clamp(value, 0, 100);
            Invalidate();
        }
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        // Blend with the card instead of Control's default gray.
        using var brush = new SolidBrush(Palette.Card);
        e.Graphics.FillRectangle(brush, e.ClipRectangle);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        var bounds = new Rectangle(0, 0, Width - 1, Height - 1);
        using var track = new Pen(Palette.Track, Height - 1);
        track.StartCap = System.Drawing.Drawing2D.LineCap.Round;
        track.EndCap = System.Drawing.Drawing2D.LineCap.Round;
        g.DrawLine(track, 1, Height / 2f, Width - 2, Height / 2f);

        var fill = Math.Clamp(Percent, 0, 100) / 100.0 * (Width - 4);
        if (fill < 1)
        {
            return;
        }

        using var pen = new Pen(Palette.QuotaColor(Percent), Height - 1)
        {
            StartCap = System.Drawing.Drawing2D.LineCap.Round,
            EndCap = System.Drawing.Drawing2D.LineCap.Round,
        };
        g.DrawLine(pen, 2, Height / 2f, 2 + (float)fill, Height / 2f);
    }
}

/// <summary>Thin Win11-style overlay scrollbar pill. Mouse-transparent: WM_NCHITTEST
/// returns HTTRANSPARENT so hover/clicks fall through to the content beneath.</summary>
internal sealed class ScrollPill : Control
{
    public ScrollPill()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        Width = 4;
    }

    public NativePalette Palette { get; set; } = NativePalette.System();

    protected override void WndProc(ref Message m)
    {
        const int wmNcHitTest = 0x84;
        const int htTransparent = -1;
        if (m.Msg == wmNcHitTest)
        {
            m.Result = (IntPtr)htTransparent;
            return;
        }

        base.WndProc(ref m);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        var color = Palette.IsDark ? Color.FromArgb(76, 76, 76) : Color.FromArgb(190, 190, 190);
        using var brush = new SolidBrush(color);
        using var path = Gdi.RoundedRect(new Rectangle(0, 0, Width - 1, Height - 1), Width / 2);
        g.FillPath(brush, path);
    }
}

/// <summary>Remaining-quota trend chart in the macOS QuotaAreaChart idiom: rounded plot,
/// L axes + 100%/0 labels, warning-threshold guide, time-proportional polyline with a
/// gradient area fill and end marker, first/last sample times underneath.</summary>
internal sealed class Sparkline : Control
{
    private IReadOnlyList<QuotaSamplePoint> _points = Array.Empty<QuotaSamplePoint>();

    public Sparkline()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        Height = 80;
    }

    public NativePalette Palette { get; set; } = NativePalette.System();

    public IReadOnlyList<QuotaSamplePoint> Points
    {
        get => _points;
        set
        {
            _points = value ?? Array.Empty<QuotaSamplePoint>();
            Invalidate();
        }
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        // Blend with the card instead of Control's default gray.
        using var brush = new SolidBrush(Palette.Card);
        e.Graphics.FillRectangle(brush, e.ClipRectangle);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        var s = DeviceDpi / 96f;
        var strip = (int)Math.Round(13 * s);
        var plot = new Rectangle(0, 0, Width - 1, Height - strip - 1);

        // Rounded plot backdrop, subtle against the card.
        using (var backdrop = new SolidBrush(Palette.IsDark ? Color.FromArgb(48, 48, 48) : Color.FromArgb(247, 247, 247)))
        using (var backdropPath = Gdi.RoundedRect(plot, (int)Math.Round(6 * s)))
        {
            g.FillPath(backdrop, backdropPath);
        }

        using (var axis = new Pen(Palette.CardBorder, 1f))
        {
            g.DrawLine(axis, plot.Left, plot.Top, plot.Left, plot.Bottom);
            g.DrawLine(axis, plot.Left, plot.Bottom, plot.Right, plot.Bottom);
            using var grid = new Pen(Palette.Track, 1f);
            for (var fraction = 0.25; fraction < 0.99; fraction += 0.25)
            {
                var y = plot.Bottom - (int)Math.Round((plot.Bottom - plot.Top) * fraction);
                g.DrawLine(grid, plot.Left + 1, y, plot.Right, y);
            }
        }

        // Warning-threshold guide (25% remaining), orange dashed as on macOS.
        var warnY = plot.Bottom - (int)Math.Round((plot.Bottom - plot.Top) * (QuotaThresholds.OrangeRemainingPercent / 100.0));
        using (var warn = new Pen(Color.FromArgb(235, 170, 70), 1f) { DashStyle = System.Drawing.Drawing2D.DashStyle.Dash })
        {
            g.DrawLine(warn, plot.Left + 1, warnY, plot.Right, warnY);
        }

        using var labelFont = new Font("Segoe UI", 7f);
        using var faint = new SolidBrush(Palette.TextFaint);
        var labelSize = TextRenderer.MeasureText("100%", labelFont);
        g.DrawString("100%", labelFont, faint, plot.Left + 3, plot.Top + 1);
        g.DrawString("0", labelFont, faint, plot.Left + 3, plot.Bottom - labelSize.Height);

        if (_points.Count < 2)
        {
            using var font = new Font("Segoe UI", 8f);
            g.DrawString("收集趋势中…", font, faint, 2 + 3 * s, (plot.Top + plot.Bottom - font.Height) / 2f);
            return;
        }

        // Time-proportional x positions across the observed sample range.
        var t0 = _points[0].AtUtc;
        var t1 = _points[^1].AtUtc;
        var span = Math.Max((t1 - t0).TotalSeconds, 1);
        var Y = (double remaining) => plot.Bottom - (remaining / 100.0 * (plot.Bottom - plot.Top));
        var X = (DateTimeOffset t) => (float)(plot.Left + 1 + (t - t0).TotalSeconds / span * (plot.Right - plot.Left - 2));

        var poly = new List<PointF>(_points.Count);
        foreach (var point in _points)
        {
            poly.Add(new PointF(X(point.AtUtc), (float)Y(Math.Clamp(point.RemainingPercent, 0, 100))));
        }

        var tint = Palette.QuotaColor(_points[^1].RemainingPercent);
        var area = new System.Drawing.Drawing2D.GraphicsPath();
        area.AddLine(plot.Left + 1, plot.Bottom, poly[0].X, poly[0].Y);
        for (var i = 1; i < poly.Count; i++)
        {
            area.AddLine(poly[i - 1].X, poly[i - 1].Y, poly[i].X, poly[i].Y);
        }

        area.AddLine(poly[^1].X, poly[^1].Y, poly[^1].X, plot.Bottom);
        area.AddLine(poly[^1].X, plot.Bottom, plot.Left + 1, plot.Bottom);
        area.CloseFigure();
        var fillRect = new Rectangle(plot.Left + 1, plot.Top, plot.Right - plot.Left - 1, plot.Bottom - plot.Top);
        if (fillRect.Width > 0 && fillRect.Height > 0)
        {
            using var gradient = new System.Drawing.Drawing2D.LinearGradientBrush(
                fillRect,
                Color.FromArgb(56, tint),
                Color.FromArgb(8, tint),
                System.Drawing.Drawing2D.LinearGradientMode.Vertical);
            g.FillPath(gradient, area);
        }

        using (var line = new Pen(tint, 1.5f * s))
        {
            g.DrawLines(line, poly.ToArray());
        }

        var dotRadius = 2.5f * s;
        using var dot = new SolidBrush(tint);
        g.FillEllipse(dot, poly[^1].X - dotRadius, poly[^1].Y - dotRadius, dotRadius * 2, dotRadius * 2);

        // First/last sample times under the plot (local time).
        g.DrawString(t0.ToLocalTime().ToString("MM-dd HH:mm"), labelFont, faint, plot.Left + 3, plot.Bottom + 2);
        var lastLabel = t1.ToLocalTime().ToString("MM-dd HH:mm");
        var lastSize = TextRenderer.MeasureText(lastLabel, labelFont);
        g.DrawString(lastLabel, labelFont, faint, plot.Right - lastSize.Width, plot.Bottom + 2);
    }
}
