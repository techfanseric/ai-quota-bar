using System.Runtime.InteropServices;
using AQB.Core;

namespace AQB.App;

/// <summary>Palette + window chrome aligned with the system (native Windows flyout look).</summary>
internal sealed class NativePalette
{
    public Color Background { get; init; }

    public Color Card { get; init; }

    public Color CardBorder { get; init; }

    public Color TextPrimary { get; init; }

    public Color TextSecondary { get; init; }

    public Color TextFaint { get; init; }

    public Color Track { get; init; }

    public bool IsDark { get; init; }

    public static NativePalette System()
    {
        var light = IsSystemLightTheme();
        return light
            ? new NativePalette
            {
                IsDark = false,
                Background = Color.FromArgb(243, 243, 243),
                Card = Color.FromArgb(255, 255, 255),
                CardBorder = Color.FromArgb(229, 229, 229),
                TextPrimary = Color.FromArgb(26, 26, 26),
                TextSecondary = Color.FromArgb(90, 90, 90),
                TextFaint = Color.FromArgb(130, 130, 130),
                Track = Color.FromArgb(229, 229, 229),
            }
            : new NativePalette
            {
                IsDark = true,
                Background = Color.FromArgb(32, 32, 32),
                Card = Color.FromArgb(43, 43, 43),
                CardBorder = Color.FromArgb(56, 56, 56),
                TextPrimary = Color.FromArgb(245, 245, 245),
                TextSecondary = Color.FromArgb(158, 158, 158),
                TextFaint = Color.FromArgb(120, 120, 120),
                Track = Color.FromArgb(58, 58, 58),
            };
    }

    public Color QuotaColor(double remainingPercent) => remainingPercent switch
    {
        < QuotaThresholds.RedRemainingPercent => Color.FromArgb(232, 90, 90),
        < QuotaThresholds.OrangeRemainingPercent => Color.FromArgb(235, 170, 70),
        _ => IsDark ? Color.FromArgb(96, 200, 145) : Color.FromArgb(35, 150, 95),
    };

    private static bool IsSystemLightTheme()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            if (key?.GetValue("AppsUseLightTheme") is int value)
            {
                return value == 1;
            }
        }
        catch
        {
            // Registry unavailable: default to dark, matching the tray icon.
        }

        return false;
    }
}

internal static class NativeChrome
{
    public const int DwmwaWindowCornerPreference = 33;
    public const int DwmwaRound = 2;
    public const int DwmwaBorderColor = 34;

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    /// <summary>Win11 rounded corners + subtle border; silently harmless on Win10.</summary>
    public static void ApplyRounded(Form form)
    {
        _ = form.Handle; // force creation
        var preference = DwmwaRound;
        _ = DwmSetWindowAttribute(form.Handle, DwmwaWindowCornerPreference, ref preference, sizeof(int));
    }

    /// <summary>Classic drop shadow on Win10 via window class style.</summary>
    public static void ApplyBorderlessShadow(Form form)
    {
        // CS_DROPSHADOW (0x20000) — small native shadow for borderless popups on Win10.
        const int csDropShadow = 0x20000;
        var style = GetWindowLong(form.Handle, -16);
        _ = SetWindowLong(form.Handle, -16, style | csDropShadow);
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
}

/// <summary>Common GDI+ helpers for the custom-drawn cards.</summary>
internal static class Gdi
{
    public static System.Drawing.Drawing2D.GraphicsPath RoundedRect(Rectangle bounds, int radius)
    {
        var path = new System.Drawing.Drawing2D.GraphicsPath();
        if (radius <= 0 || bounds.Width < 2 * radius || bounds.Height < 2 * radius)
        {
            path.AddRectangle(bounds);
            return path;
        }

        var d = radius * 2;
        path.AddArc(bounds.Left, bounds.Top, d, d, 180, 90);
        path.AddArc(bounds.Right - d, bounds.Top, d, d, 270, 90);
        path.AddArc(bounds.Right - d, bounds.Bottom - d, d, d, 0, 90);
        path.AddArc(bounds.Left, bounds.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    public static void FillRounded(Graphics g, Color color, Rectangle bounds, int radius)
    {
        using var brush = new SolidBrush(color);
        using var path = RoundedRect(bounds, radius);
        g.FillPath(brush, path);
    }

    public static void DrawRoundedBorder(Graphics g, Color color, Rectangle bounds, int radius, float width = 1f)
    {
        using var pen = new Pen(color, width);
        using var path = RoundedRect(bounds, radius);
        g.DrawPath(pen, path);
    }
}
