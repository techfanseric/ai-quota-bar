// Swift 来源：Models/符号渲染器 + scripts/generate-quota-icons 管线的运行时轻量版。
// Windows 托盘图标使用可辨识的「Q / quota meter」：外环表示剩余比例，右下短尾让它在
// 16px 下仍区别于普通 loading spinner。正常态跟随系统明暗保持单色，只有低余量才用告警色。

using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace AIQuotaBar.App.Services;

public static class RingIconFactory
{
    public static IntPtr Create(int? percent, bool darkSurface)
    {
        var dpi = GetDpiForSystem();
        var size = Math.Max(16, (int)(16L * dpi / 96));
        using var bitmap = new Bitmap(size, size);
        using var g = Graphics.FromImage(bitmap);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Color.Transparent);

        var foreground = darkSurface
            ? Color.FromArgb(238, 246, 246, 246)
            : Color.FromArgb(224, 28, 28, 30);
        var active = percent switch
        {
            <= 15 => Color.FromArgb(255, 232, 72, 86),
            <= 35 => Color.FromArgb(255, 221, 156, 28),
            _ => foreground,
        };
        var track = darkSurface
            ? Color.FromArgb(72, 246, 246, 246)
            : Color.FromArgb(58, 28, 28, 30);

        var scale = size / 16f;
        var thickness = Math.Max(2f, 2.15f * scale);
        var ringBounds = new RectangleF(2.1f * scale, 1.6f * scale, 11.4f * scale, 11.4f * scale);

        using (var trackPen = new Pen(track, thickness))
        {
            trackPen.StartCap = LineCap.Round;
            trackPen.EndCap = LineCap.Round;
            g.DrawEllipse(trackPen, ringBounds);
        }

        using var arc = new Pen(active, thickness)
        {
            StartCap = LineCap.Round,
            EndCap = LineCap.Round,
        };
        if (percent >= 99)
        {
            g.DrawEllipse(arc, ringBounds);
        }
        else if (percent is > 0)
        {
            g.DrawArc(arc, ringBounds, -90, 360f * Math.Clamp(percent.Value, 0, 100) / 100f);
        }

        // Q 尾始终实色：无数据时图标仍有产品识别度，不会退化为灰色空圈。
        using var tail = new Pen(percent is null ? foreground : active, Math.Max(1.7f, 1.9f * scale))
        {
            StartCap = LineCap.Round,
            EndCap = LineCap.Round,
        };
        g.DrawLine(tail, 9.7f * scale, 9.8f * scale, 14.1f * scale, 14.1f * scale);

        return bitmap.GetHicon();
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForSystem();
}
