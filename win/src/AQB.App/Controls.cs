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

/// <summary>Flat hover-highlight glyph button (Segoe MDL2 Assets), Windows 11 flyout style:
/// 28dip square, rounded hover fill, no chrome.</summary>
internal sealed class IconButton : Control
{
    private bool _hover;
    private bool _pressed;

    public IconButton(string glyph)
    {
        Glyph = glyph;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
        Cursor = Cursors.Hand;
    }

    public string Glyph { get; set; }

    public NativePalette Palette { get; set; } = NativePalette.System();

    protected override void OnMouseEnter(EventArgs e)
    {
        _hover = true;
        Invalidate();
        base.OnMouseEnter(e);
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        _hover = false;
        _pressed = false;
        Invalidate();
        base.OnMouseLeave(e);
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        _pressed = true;
        Invalidate();
        base.OnMouseDown(e);
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        _pressed = false;
        Invalidate();
        base.OnMouseUp(e);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        if (_hover)
        {
            var fill = _pressed
                ? Palette.IsDark ? Color.FromArgb(62, 62, 62) : Color.FromArgb(232, 232, 232)
                : Palette.IsDark ? Color.FromArgb(56, 56, 56) : Color.FromArgb(239, 239, 239);
            using var brush = new SolidBrush(fill);
            using var path = Gdi.RoundedRect(new Rectangle(0, 0, Width - 1, Height - 1), (int)Math.Round(4 * (DeviceDpi / 96f)));
            g.FillPath(brush, path);
        }

        using var font = new Font("Segoe MDL2 Assets", 9f);
        TextRenderer.DrawText(g, Glyph, font, ClientRectangle,
            _hover ? Palette.TextPrimary : Palette.TextSecondary,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
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

/// <summary>Current-cycle area chart in the macOS QuotaAreaChart idiom. The x axis IS the
/// quota window (start → end = reset moment), so the curve reads against a constant-pace
/// diagonal from 100% down to 0%; hour/day tick lines, 25% warning guide, gradient area
/// fill, end marker, and window-edge time labels complete the reading.</summary>
internal sealed class QuotaAreaChart : Control
{
    private IReadOnlyList<QuotaSamplePoint> _points = Array.Empty<QuotaSamplePoint>();

    public QuotaAreaChart()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        Height = 80;
    }

    public NativePalette Palette { get; set; } = NativePalette.System();

    /// <summary>Cycle bounds: x axis span. For rolling windows (GLM 5h) the caller passes
    /// (now-5h, now) exactly like macOS quotaChartWindow().</summary>
    public DateTimeOffset WindowStart { get; set; }

    public DateTimeOffset WindowEnd { get; set; }

    /// <summary>Constant-pace stage for the diagonal guide; null (rolling window) skips it.</summary>
    public bool? PaceIsReserve { get; set; }

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
        var isMultiDay = WindowEnd - WindowStart > TimeSpan.FromHours(24);

        // Rounded plot backdrop, subtle against the card.
        using (var backdrop = new SolidBrush(Palette.IsDark ? Color.FromArgb(48, 48, 48) : Color.FromArgb(247, 247, 247)))
        using (var backdropPath = Gdi.RoundedRect(plot, (int)Math.Round(6 * s)))
        {
            g.FillPath(backdrop, backdropPath);
        }

        float Y(double remaining) => plot.Bottom - (float)(Math.Clamp(remaining, 0, 100) / 100.0 * (plot.Bottom - plot.Top));
        double XRatio(DateTimeOffset t) => Math.Clamp((t - WindowStart).TotalSeconds / Math.Max((WindowEnd - WindowStart).TotalSeconds, 1), 0, 1);
        float X(DateTimeOffset t) => (float)(plot.Left + 1 + XRatio(t) * (plot.Right - plot.Left - 2));

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

        // Time ticks: whole hours for short cycles, local midnights for multi-day ones
        // (mac QuotaChartTimeTickBuilder), faint vertical dashes.
        using (var tick = new Pen(Palette.Track, 1f) { DashPattern = new float[] { 2, 3 } })
        {
            foreach (var t in TimeTicks(isMultiDay))
            {
                var x = X(t);
                if (x > plot.Left + 2 && x < plot.Right - 2)
                {
                    g.DrawLine(tick, x, plot.Top + 1, x, plot.Bottom - 1);
                }
            }
        }

        // Constant-pace diagonal: 100% at cycle start → 0% at reset. Green when running
        // behind schedule (reserve), red when ahead (deficit) — same colors as macOS.
        if (PaceIsReserve is { } reserve)
        {
            var paceColor = reserve
                ? Palette.IsDark ? Color.FromArgb(96, 200, 145) : Color.FromArgb(35, 150, 95)
                : Color.FromArgb(232, 90, 90);
            using var pace = new Pen(Color.FromArgb(150, paceColor), 1f)
            {
                DashStyle = System.Drawing.Drawing2D.DashStyle.Dash,
                DashPattern = new float[] { 3, 3 },
            };
            g.DrawLine(pace, plot.Left + 1, Y(100), plot.Right, Y(0));
        }

        using var labelFont = new Font("Segoe UI", 7f);
        using var faint = new SolidBrush(Palette.TextFaint);
        var labelSize = TextRenderer.MeasureText("100%", labelFont);
        g.DrawString("100%", labelFont, faint, plot.Left + 3, plot.Top + 1);
        g.DrawString("0", labelFont, faint, plot.Left + 3, plot.Bottom - labelSize.Height);

        // Samples inside the cycle only; the caller falls back to a capsule bar when
        // there is nothing to plot.
        var poly = new List<PointF>(_points.Count);
        foreach (var point in _points)
        {
            if (point.AtUtc >= WindowStart && point.AtUtc <= WindowEnd)
            {
                poly.Add(new PointF(X(point.AtUtc), Y(point.RemainingPercent)));
            }
        }

        if (poly.Count >= 2)
        {
            var tint = Palette.QuotaColor(_points[^1].RemainingPercent);
            var area = new System.Drawing.Drawing2D.GraphicsPath();
            area.AddLine(poly[0].X, plot.Bottom, poly[0].X, poly[0].Y);
            for (var i = 1; i < poly.Count; i++)
            {
                area.AddLine(poly[i - 1].X, poly[i - 1].Y, poly[i].X, poly[i].Y);
            }

            area.AddLine(poly[^1].X, poly[^1].Y, poly[^1].X, plot.Bottom);
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
        }

        // Window-edge labels: cycle start (left) and reset moment (right).
        var format = isMultiDay ? "MM-dd" : "HH:mm";
        g.DrawString(WindowStart.ToLocalTime().ToString(format), labelFont, faint, plot.Left + 3, plot.Bottom + 2);
        var endLabel = WindowEnd.ToLocalTime().ToString(format);
        var endSize = TextRenderer.MeasureText(endLabel, labelFont);
        g.DrawString(endLabel, labelFont, faint, plot.Right - endSize.Width, plot.Bottom + 2);
    }

    private IEnumerable<DateTimeOffset> TimeTicks(bool isMultiDay)
    {
        if (isMultiDay)
        {
            var local = WindowStart.ToLocalTime().Date.AddDays(1);
            var endLocal = WindowEnd.ToLocalTime();
            for (var day = local; day <= endLocal; day = day.AddDays(1))
            {
                yield return day.ToUniversalTime();
            }
        }
        else
        {
            var hour = WindowStart.ToLocalTime();
            hour = hour.AddMinutes(60 - hour.Minute);
            var end = WindowEnd.ToLocalTime();
            for (var t = hour; t < end; t = t.AddHours(1))
            {
                yield return t.ToUniversalTime();
            }
        }
    }
}

/// <summary>One utilization cycle: the quota pool between two resets.</summary>
internal sealed record UtilizationCycle(DateTimeOffset ResetsAtUtc, double PeakUsedPercent, bool IsCurrent);

/// <summary>Cycle detection over the flat sample series: a remaining jump of more than
/// 10pp upward marks a reset boundary; each segment becomes one cycle with its peak
/// (100 - minimum remaining) as the bar height.</summary>
internal static class CycleDetection
{
    public static List<UtilizationCycle> Detect(IReadOnlyList<QuotaSamplePoint> points, int limit = 30)
    {
        var cycles = new List<UtilizationCycle>();
        var start = 0;
        for (var i = 1; i < points.Count; i++)
        {
            if (points[i].RemainingPercent - points[i - 1].RemainingPercent > 10)
            {
                cycles.Add(new UtilizationCycle(points[i].AtUtc, PeakUsed(points, start, i - 1), IsCurrent: false));
                start = i;
            }
        }

        cycles.Add(new UtilizationCycle(default, PeakUsed(points, start, points.Count - 1), IsCurrent: true));
        return cycles.Skip(Math.Max(0, cycles.Count - limit)).ToList();

        static double PeakUsed(IReadOnlyList<QuotaSamplePoint> points, int from, int to)
        {
            var min = 100.0;
            for (var i = from; i <= to && i < points.Count; i++)
            {
                min = Math.Min(min, points[i].RemainingPercent);
            }

            return Math.Clamp(100 - min, 0, 100);
        }
    }
}

/// <summary>Cross-cycle utilization bars (mac ModelUtilizationBarsView): one bar = one
/// past cycle, height = that cycle's peak used percent; the in-progress cycle is solid,
/// history is muted. Newest at the right, growing leftwards as history accumulates.</summary>
internal sealed class UtilizationBars : Control
{
    private IReadOnlyList<UtilizationCycle> _cycles = Array.Empty<UtilizationCycle>();

    public UtilizationBars()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        Height = 24;
    }

    public NativePalette Palette { get; set; } = NativePalette.System();

    public IReadOnlyList<UtilizationCycle> Cycles
    {
        get => _cycles;
        set
        {
            _cycles = value ?? Array.Empty<UtilizationCycle>();
            Invalidate();
        }
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        using var brush = new SolidBrush(Palette.Card);
        e.Graphics.FillRectangle(brush, e.ClipRectangle);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        if (_cycles.Count == 0)
        {
            return;
        }

        var g = e.Graphics;
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        var s = DeviceDpi / 96f;
        var gap = Math.Max(1f, 2f * s);
        var minBar = 3f * s;
        var maxBar = 10f * s;
        var barWidth = Math.Clamp((Width - 1 - gap * (_cycles.Count - 1)) / _cycles.Count, minBar, maxBar);
        var barTop = 1f;
        var barMaxHeight = Height - 2;
        var tint = _cycles.Count > 0
            ? Palette.QuotaColor(100 - _cycles[^1].PeakUsedPercent)
            : Palette.QuotaColor(100);
        var muted = Palette.IsDark ? Color.FromArgb(96, 120, 108) : Color.FromArgb(178, 192, 186);

        // Right-aligned: the current cycle pins to the right edge.
        var x = Width - 1f;
        for (var i = _cycles.Count - 1; i >= 0; i--)
        {
            var cycle = _cycles[i];
            var height = (float)Math.Max(2 * s, cycle.PeakUsedPercent / 100.0 * barMaxHeight);
            var rect = new RectangleF(x - barWidth, barTop + (barMaxHeight - height), barWidth, height);
            if (rect.Width > 0 && rect.Height > 0)
            {
                using var brush = new SolidBrush(cycle.IsCurrent ? tint : muted);
                using var path = Gdi.RoundedRect(Rectangle.Round(rect), (int)Math.Round(1.5f * s));
                g.FillPath(brush, path);
            }

            x -= barWidth + gap;
        }

        using var baseline = new Pen(Palette.CardBorder, 1f);
        g.DrawLine(baseline, 0, Height - 1, Width - 1, Height - 1);
    }
}
