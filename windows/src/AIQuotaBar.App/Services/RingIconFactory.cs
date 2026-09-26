// Swift 来源：Models/符号渲染器 + scripts/generate-quota-icons 管线的运行时轻量版。
// 托盘环形图标：DPI 缩放（16px@96 基准）、剩余比例弧、颜色分段（>50 绿 / >20 黄 / 其余红；
// 无数据灰）。30fps 动画与多档预生成资产留给 W2 后续性能阶段（计划 §11 限帧）。

using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace AIQuotaBar.App.Services;

public static class RingIconFactory
{
    public static IntPtr Create(int? percent)
    {
        var dpi = GetDpiForSystem();
        var size = Math.Max(16, (int)(16L * dpi / 96));
        using var bitmap = new Bitmap(size, size);
        using var g = Graphics.FromImage(bitmap);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Color.Transparent);

        var color = percent is null
            ? Color.FromArgb(120, 120, 128)
            : percent > 50
                ? Color.FromArgb(76, 175, 80)
                : percent > 20
                    ? Color.FromArgb(245, 180, 40)
                    : Color.FromArgb(220, 60, 60);

        var thickness = Math.Max(2, size / 5);
        var rect = new Rectangle(thickness / 2, thickness / 2, size - thickness, size - thickness);

        using (var track = new Pen(Color.FromArgb(70, 70, 76), thickness))
        {
            g.DrawEllipse(track, rect);
        }

        using var arc = new Pen(color, thickness);
        if (percent >= 100)
        {
            g.DrawEllipse(arc, rect);
        }
        else if (percent is > 0)
        {
            g.DrawArc(arc, rect, -90, 360f * percent.Value / 100f);
        }

        return bitmap.GetHicon();
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForSystem();
}
