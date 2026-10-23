using AQB.Core;

namespace AQB.App;

/// <summary>
/// Renders the tray icon. detailedText mode draws "C:74% · 3.2h"-style compact text;
/// compactRing mode draws the provider ring (letter + quota arc + pace wings).
/// </summary>
internal static class TrayIconRenderer
{
    private const float RingSweep = 256f;
    private const float RingStart = (360f - RingSweep) / 2f + 90f;

    public static string BuildDetailedText(IReadOnlyDictionary<ProviderKind, ProviderSnapshot> snapshots)
    {
        var codex = snapshots.GetValueOrDefault(ProviderKind.Codex);
        var windows = codex?.Accounts.FirstOrDefault()?.Windows;
        var primary = windows?.FirstOrDefault(w => w.Role == QuotaWindowRole.Primary)
            ?? windows?.FirstOrDefault();
        if (primary is not null && codex!.Status == ProviderStatus.Ok)
        {
            var remaining = primary.RemainingPercent;
            var time = TimeText.FormatRemaining(TimeSpan.FromSeconds(Math.Max(0, (primary.ResetsAtUtc - DateTimeOffset.UtcNow).TotalSeconds)));
            return $"C:{remaining:0}% · {time}";
        }

        if (codex is not null && codex.Status is ProviderStatus.Failed or ProviderStatus.Offline)
        {
            return "C:--";
        }

        // Fall back to the lowest-remaining provider of the others.
        ProviderKind? lowestKind = null;
        var lowest = 100.0;
        foreach (var (kind, snapshot) in snapshots)
        {
            if (kind == ProviderKind.Codex || snapshot.Status != ProviderStatus.Ok)
            {
                continue;
            }

            var window = snapshot.Accounts.FirstOrDefault()?.Windows.FirstOrDefault();
            if (window is null)
            {
                continue;
            }

            if (window.RemainingPercent < lowest)
            {
                lowest = window.RemainingPercent;
                lowestKind = kind;
            }
        }

        return lowestKind is null ? "AI Quota Bar" : $"{lowestKind.Value.Letter()}:{lowest:0}%";
    }

    public static Bitmap RenderCompactRing(
        IReadOnlyDictionary<ProviderKind, ProviderSnapshot> snapshots,
        int size = 32,
        float dpiScale = 1f)
    {
        var bitmap = new Bitmap(size, size);
        bitmap.SetResolution(96 * dpiScale, 96 * dpiScale);
        using var g = Graphics.FromImage(bitmap);
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        DrawBadge(g, size);

        var center = size / 2f;
        var ringRadius = size * 0.40f;
        var trackPen = new Pen(Color.FromArgb(160, 174, 192), Math.Max(2f, size * 0.09f));

        var snapshot = PickRingProvider(snapshots);
        if (snapshot is null)
        {
            // Placeholder: muted open ring.
            g.DrawArc(trackPen, RingRect(center, ringRadius), RingStart, RingSweep);
            trackPen.Dispose();
            return bitmap;
        }

        var window = snapshot.Accounts.FirstOrDefault()?.Windows.FirstOrDefault();
        if (window is null)
        {
            g.DrawArc(trackPen, RingRect(center, ringRadius), RingStart, RingSweep);
            trackPen.Dispose();
            return bitmap;
        }

        var remaining = Math.Clamp(window.RemainingPercent, 0, 100);
        var ringColor = remaining switch
        {
            < QuotaThresholds.RedRemainingPercent => Color.FromArgb(220, 60, 60),
            < QuotaThresholds.OrangeRemainingPercent => Color.FromArgb(230, 160, 40),
            _ => Color.FromArgb(80, 190, 120),
        };
        if (snapshot.Status is ProviderStatus.Failed or ProviderStatus.Offline)
        {
            ringColor = Color.FromArgb(220, 60, 60);
        }

        g.DrawArc(trackPen, RingRect(center, ringRadius), RingStart, RingSweep);
        trackPen.Dispose();

        using var fillPen = new Pen(ringColor, Math.Max(2.5f, size * 0.11f));
        var sweep = RingSweep * remaining / 100.0;
        g.DrawArc(fillPen, RingRect(center, ringRadius), RingStart, (float)sweep);

        // Provider letter in the center.
        using var font = new Font("Segoe UI", size * 0.32f, FontStyle.Bold, GraphicsUnit.Pixel);
        using var brush = new SolidBrush(Color.White);
        var text = snapshot.Kind.Letter().ToString();
        var textSize = g.MeasureString(text, font);
        g.DrawString(text, font, brush, center - textSize.Width / 2f, center - textSize.Height / 2f);

        return bitmap;
    }

    private static ProviderSnapshot? PickRingProvider(IReadOnlyDictionary<ProviderKind, ProviderSnapshot> snapshots)
    {
        ProviderSnapshot? pick = null;
        var lowest = 100.0;
        foreach (var snapshot in snapshots.Values)
        {
            if (snapshot.Status != ProviderStatus.Ok || snapshot.Accounts.Count == 0)
            {
                continue;
            }

            var window = snapshot.Accounts[0].Windows.FirstOrDefault();
            if (window is null)
            {
                continue;
            }

            if (pick is null || window.RemainingPercent < lowest)
            {
                lowest = window.RemainingPercent;
                pick = snapshot;
            }
        }

        return pick;
    }

    private static RectangleF RingRect(float center, float radius) =>
        new(center - radius, center - radius, radius * 2, radius * 2);

    // A dark badge with a light edge stays visible on both taskbar themes,
    // including translucent taskbars whose background depends on the wallpaper.
    private static void DrawBadge(Graphics g, int size)
    {
        g.Clear(Color.Transparent);
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        using var fill = new SolidBrush(Color.FromArgb(24, 32, 46));
        using var edge = new Pen(Color.FromArgb(205, 218, 235), Math.Max(1f, size / 32f));
        var bounds = new RectangleF(size * 0.025f, size * 0.025f, size * 0.95f, size * 0.95f);
        g.FillEllipse(fill, bounds);
        g.DrawEllipse(edge, bounds);
    }

    public static Bitmap RenderTextIcon(string text, int size = 32)
    {
        var bitmap = new Bitmap(size, size);
        using var g = Graphics.FromImage(bitmap);
        DrawBadge(g, size);
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        var parts = text.Split(':', 2);
        var label = parts.Length == 2 ? parts[0] : "AI";
        var value = parts.Length == 2 ? parts[1].Split(' ', 2)[0] : "";
        using var font = new Font("Segoe UI", size * 0.32f, FontStyle.Bold, GraphicsUnit.Pixel);
        using var brush = new SolidBrush(Color.White);
        using var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
        if (value.Length == 0)
        {
            g.DrawString(label, font, brush, new RectangleF(0, 0, size, size), format);
        }
        else
        {
            g.DrawString(label, font, brush, new RectangleF(0, size * 0.08f, size, size * 0.40f), format);
            g.DrawString(value, font, brush, new RectangleF(0, size * 0.46f, size, size * 0.42f), format);
        }
        return bitmap;
    }
}
