// Swift 来源：App/NSPopover 形态（左右键弹层）—— Windows 原生表达：
// 无边框亚克力小窗（Win10 SetWindowCompositionAttribute ACCENT_ENABLE_ACRYLICBLURBEHIND）
// + Shell_NotifyIconGetRect 定位到托盘旁 + 失焦/ESC 自动关闭（计划 §8 弹层验收项）。
// 任务栏四向对齐：v1 处理底部任务栏（左右对齐图标矩形）；其余方向待多显示器验收阶段补。

using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;

namespace AIQuotaBar.App.Panels;

public abstract class PopupWindow : Window
{
    private const int AccentEnableAcrylicBlurBehind = 4;

    protected PopupWindow()
    {
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = true;
        Topmost = true;
        AllowsTransparency = true;
        Background = System.Windows.Media.Brushes.Transparent;
        Width = 340;
        MaxHeight = 640;
        Deactivated += (_, _) => Hide();
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                Hide();
                e.Handled = true;
            }
        };
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        ApplyAcrylic();
    }

    /// <summary>按托盘图标矩形定位弹层（底部任务栏：弹层左下角对齐图标左上角）。</summary>
    public void PositionNearTray()
    {
        var trayRect = ((App)Application.Current).TrayIconRect();
        var workArea = SystemParameters.WorkArea;
        var height = double.IsNaN(Height) ? Math.Max(ActualHeight, 320) : Height;
        Left = trayRect.HasValue
            ? Math.Min(trayRect.Value.Left - 12, workArea.Right - Width - 8)
            : workArea.Right - Width - 12;
        Top = trayRect.HasValue
            ? trayRect.Value.Top - height - 12
            : workArea.Bottom - height - 12;
        // SizeToContent 场景：首次布局完成后高度才真实，再校一次位置。
        ContentRendered -= RepositionOnRendered;
        ContentRendered += RepositionOnRendered;
    }

    private void RepositionOnRendered(object? sender, EventArgs e) => PositionNearTray();

    private void ApplyAcrylic()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        var accent = new AccentPolicy
        {
            AccentState = AccentEnableAcrylicBlurBehind,
            GradientColor = 0xCC202020, // AARRGGBB：底色叠加在亚克力模糊之上
        };
        var accentSize = Marshal.SizeOf<AccentPolicy>();
        var accentPtr = Marshal.AllocHGlobal(accentSize);
        try
        {
            Marshal.StructureToPtr(accent, accentPtr, false);
            var data = new WindowCompositionAttributeData
            {
                Attribute = 0x13 /* WCA_ACCENT_POLICY */,
                DataPointer = accentPtr,
                DataSize = accentSize,
            };
            _ = SetWindowCompositionAttribute(hwnd, ref data);
        }
        finally
        {
            Marshal.FreeHGlobal(accentPtr);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct AccentPolicy
    {
        public int AccentState;
        public int AccentFlags;
        public uint GradientColor;
        public int AnimationId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WindowCompositionAttributeData
    {
        public int Attribute;
        public IntPtr DataPointer;
        public int DataSize;
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowCompositionAttribute(IntPtr hwnd, ref WindowCompositionAttributeData data);
}
