// Swift 来源：App/NSPopover 形态。Windows 端使用不透明 DWM 工具弹层：系统负责阴影、
// Win11 圆角与窗口合成；内容自己跟随应用主题。避免旧式 SetWindowCompositionAttribute
// 亚克力和透明 WPF 窗口造成的“仿原生”边缘、文字发虚与缩放问题。

using System.Runtime.InteropServices;
using Application = System.Windows.Application;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using AIQuotaBar.App.Services;

namespace AIQuotaBar.App.Panels;

public abstract class PopupWindow : Window
{
    private const int DwmwaUseImmersiveDarkMode = 20;
    private const int DwmwaWindowCornerPreference = 33;
    private const int DwmWindowCornerPreferenceRoundSmall = 3;
    private const uint MonitorDefaultToNearest = 2;
    private IntPtr _hwnd;

    protected PopupWindow()
    {
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = true;
        Topmost = true;
        AllowsTransparency = false;
        SetResourceReference(BackgroundProperty, "PanelBackground");
        Width = 380;
        MaxHeight = 680;
        Deactivated += (_, _) => Hide();
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                Hide();
                e.Handled = true;
            }
        };
        ThemeService.Instance.ThemeChanged += ApplyNativeWindowTheme;
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        _hwnd = new WindowInteropHelper(this).Handle;
        ApplyNativeWindowTheme();
    }

    /// <summary>按托盘所在显示器和任务栏方向定位；Win32 物理像素先转换为 WPF DIP。</summary>
    public void PositionNearTray()
    {
        var trayPixels = ((App)Application.Current).TrayIconRect();
        var fromDevice = _hwnd == IntPtr.Zero
            ? System.Windows.Media.Matrix.Identity
            : HwndSource.FromHwnd(_hwnd)?.CompositionTarget?.TransformFromDevice
                ?? System.Windows.Media.Matrix.Identity;
        var tray = trayPixels is { } rawTray ? TransformRect(rawTray, fromDevice) : (Rect?)null;
        var work = trayPixels is { } raw
            ? WorkAreaFor(raw, fromDevice)
            : SystemParameters.WorkArea;
        var height = ActualHeight > 0 ? ActualHeight : 420;
        const double gap = 8;

        var left = tray?.Left ?? work.Right - Width - gap;
        var top = tray?.Top - height - gap ?? work.Bottom - height - gap;
        if (tray is { } icon)
        {
            var verticalTaskbar = icon.Right <= work.Left + 2 || icon.Left >= work.Right - 2;
            var topTaskbar = icon.Bottom <= work.Top + 2;
            if (verticalTaskbar)
            {
                left = icon.Left >= work.Right - 2 ? icon.Left - Width - gap : icon.Right + gap;
                top = icon.Top;
            }
            else if (topTaskbar)
            {
                top = icon.Bottom + gap;
            }
        }

        Left = Math.Clamp(left, work.Left + gap, Math.Max(work.Left + gap, work.Right - Width - gap));
        Top = Math.Clamp(top, work.Top + gap, Math.Max(work.Top + gap, work.Bottom - height - gap));
        // SizeToContent 场景：首次布局完成后高度才真实，再校一次位置。
        ContentRendered -= RepositionOnRendered;
        ContentRendered += RepositionOnRendered;
    }

    private void RepositionOnRendered(object? sender, EventArgs e) => PositionNearTray();

    private void ApplyNativeWindowTheme()
    {
        if (_hwnd == IntPtr.Zero)
        {
            return;
        }

        var dark = ThemeService.Instance.Current == EffectiveTheme.Dark ? 1 : 0;
        _ = DwmSetWindowAttribute(_hwnd, DwmwaUseImmersiveDarkMode, ref dark, sizeof(int));
        var corners = DwmWindowCornerPreferenceRoundSmall;
        _ = DwmSetWindowAttribute(_hwnd, DwmwaWindowCornerPreference, ref corners, sizeof(int));
    }

    private static Rect WorkAreaFor(Rect trayPixels, System.Windows.Media.Matrix fromDevice)
    {
        var nativeRect = new RECT
        {
            Left = (int)trayPixels.Left,
            Top = (int)trayPixels.Top,
            Right = (int)trayPixels.Right,
            Bottom = (int)trayPixels.Bottom,
        };
        var monitor = MonitorFromRect(ref nativeRect, MonitorDefaultToNearest);
        var info = new MONITORINFO { Size = Marshal.SizeOf<MONITORINFO>() };
        return monitor != IntPtr.Zero && GetMonitorInfoW(monitor, ref info)
            ? TransformRect(new Rect(
                info.Work.Left,
                info.Work.Top,
                info.Work.Right - info.Work.Left,
                info.Work.Bottom - info.Work.Top), fromDevice)
            : SystemParameters.WorkArea;
    }

    private static Rect TransformRect(Rect rect, System.Windows.Media.Matrix transform)
    {
        var topLeft = transform.Transform(rect.TopLeft);
        var bottomRight = transform.Transform(rect.BottomRight);
        return new Rect(topLeft, bottomRight);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MONITORINFO
    {
        public int Size;
        public RECT Monitor;
        public RECT Work;
        public uint Flags;
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int valueSize);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromRect(ref RECT rect, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetMonitorInfoW(IntPtr monitor, ref MONITORINFO monitorInfo);
}
