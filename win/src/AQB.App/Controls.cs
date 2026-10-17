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

/// <summary>Remaining-quota trend sparkline fed by <see cref="QuotaHistoryStore"/> points.</summary>
internal sealed class Sparkline : Control
{
    private IReadOnlyList<QuotaSamplePoint> _points = Array.Empty<QuotaSamplePoint>();

    public Sparkline()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        Height = 30;
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

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;

        // Faint 0/50/100 grid lines for orientation.
        using (var grid = new Pen(Palette.Track, 1f))
        {
            for (var fraction = 0.25; fraction < 1.0; fraction += 0.25)
            {
                var y = Height - 1 - (int)((Height - 2) * fraction);
                g.DrawLine(grid, 0, y, Width, y);
            }
        }

        if (_points.Count < 2)
        {
            using var font = new Font("Segoe UI", 8f);
            using var brush = new SolidBrush(Palette.TextFaint);
            g.DrawString("收集趋势中…", font, brush, 2, (Height - 14) / 2f);
            return;
        }

        var latest = _points[^1].RemainingPercent;
        using var line = new Pen(Palette.QuotaColor(latest), 1.6f);
        var step = Width / (float)(_points.Count - 1);
        var previous = new PointF(0, Y(_points[0].RemainingPercent));
        for (var i = 1; i < _points.Count; i++)
        {
            var point = new PointF(i * step, Y(_points[i].RemainingPercent));
            g.DrawLine(line, previous, point);
            previous = point;
        }

        using var dot = new SolidBrush(Palette.QuotaColor(latest));
        g.FillEllipse(dot, previous.X - 2f, previous.Y - 2f, 4f, 4f);
        return;

        float Y(double remainingPercent) => Height - 1 - (float)(Math.Clamp(remainingPercent, 0, 100) / 100.0 * (Height - 2));
    }
}
