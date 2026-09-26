// Swift 来源：无（Windows 端新增；托盘常驻服务，S6 demo 的正式化）。
// 形态：隐藏顶层窗口（非 message-only —— TaskbarCreated 广播需要）+ Shell_NotifyIconW
// 直调（计划 §6 路线）。环形图标由真实配额驱动（QuotaService.RingPercent）。

using System.Runtime.InteropServices;
using System.Windows;

namespace AIQuotaBar.App.Services;

public sealed class TrayIconService : IDisposable
{
    private const uint WmApp = 0x8000;
    private const uint WmTrayIcon = WmApp + 1;
    private const uint WmDestroy = 0x0002;
    private const uint WmLbuttonup = 0x0202;
    private const uint WmRbuttonup = 0x0205;

    private const uint NifMessage = 0x01;
    private const uint NifIcon = 0x02;
    private const uint NifTip = 0x04;
    private const uint NifInfo = 0x10;
    private const uint NimAdd = 0;
    private const uint NimModify = 1;
    private const uint NimDelete = 2;
    private const uint NimGetRect = 3;

    private readonly WndProcDelegate _wndProc;
    private uint _wmTaskbarCreated;
    private IntPtr _hwnd;
    private IntPtr _hIcon = IntPtr.Zero;
    private NOTIFYICONDATA _nid;
    private int? _percent;
    private string _tooltip = "AI Quota Bar";

    public event Action? LeftClick;

    public event Action? RightClick;

    private delegate IntPtr WndProcDelegate(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);

    public TrayIconService() => _wndProc = WndProc;

    /// <summary>在 UI 线程建窗口并挂托盘图标（WPF Dispatcher 泵分发本线程窗口消息）。</summary>
    public void RunIconLoop()
    {
        _wmTaskbarCreated = RegisterWindowMessageW("TaskbarCreated");
        var wc = new WNDCLASSW
        {
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_wndProc),
            lpszClassName = "AIQuotaBarTray",
            hInstance = GetModuleHandleW(null),
        };
        _ = RegisterClassW(ref wc);
        _hwnd = CreateWindowExW(
            0, "AIQuotaBarTray", "AI Quota Bar", 0,
            0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
        AddIcon();
    }

    /// <summary>按最新配额状态刷新图标与 tooltip（UI 线程调用）。</summary>
    public void UpdateState(int? percent, string tooltip)
    {
        if (_hwnd == IntPtr.Zero)
        {
            return;
        }

        _percent = percent;
        _tooltip = tooltip.Length > 127 ? tooltip[..127] : tooltip;
        FreeIcon();
        _hIcon = RingIconFactory.Create(_percent);
        _nid.hIcon = _hIcon;
        _nid.uFlags = NifIcon | NifTip;
        _nid.szTip = _tooltip;
        _ = Shell_NotifyIconW(NimModify, ref _nid);
    }

    public void ShowBalloon(string title, string text)
    {
        if (_hwnd == IntPtr.Zero)
        {
            return;
        }

        _nid.uFlags = NifInfo;
        _nid.szInfoTitle = title;
        _nid.szInfo = text;
        _ = Shell_NotifyIconW(NimModify, ref _nid);
    }

    /// <summary>托盘图标屏幕矩形（弹层定位基准）；失败返回 null。</summary>
    public Rect? GetIconScreenRect()
    {
        var identifier = new NOTIFYICONIDENTIFIER
        {
            cbSize = (uint)Marshal.SizeOf<NOTIFYICONIDENTIFIER>(),
            hWnd = _hwnd,
            uID = 1,
        };
        return Shell_NotifyIconGetRect(ref identifier, out var rc)
            ? new Rect(rc.Left, rc.Top, rc.Right - rc.Left, rc.Bottom - rc.Top)
            : null;
    }

    public void RemoveIcon()
    {
        if (_hwnd != IntPtr.Zero)
        {
            _ = Shell_NotifyIconW(NimDelete, ref _nid);
            FreeIcon();
        }
    }

    public void Dispose() => RemoveIcon();

    private IntPtr WndProc(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam)
    {
        if (message == _wmTaskbarCreated)
        {
            AddIcon(); // Explorer 重启 → 重新 NIM_ADD（计划 §8 验收项）
            UpdateState(_percent, _tooltip);
        }
        else if (message == WmTrayIcon)
        {
            var mouse = unchecked((uint)(short)lParam);
            if (mouse == WmLbuttonup)
            {
                LeftClick?.Invoke();
            }
            else if (mouse == WmRbuttonup)
            {
                RightClick?.Invoke();
            }
        }
        else if (message == WmDestroy)
        {
            RemoveIcon();
        }

        return DefWindowProcW(hWnd, message, wParam, lParam);
    }

    private void AddIcon()
    {
        FreeIcon();
        _hIcon = RingIconFactory.Create(_percent);
        _nid = default;
        _nid.cbSize = (uint)Marshal.SizeOf<NOTIFYICONDATA>();
        _nid.hWnd = _hwnd;
        _nid.uID = 1;
        _nid.uFlags = NifMessage | NifIcon | NifTip;
        _nid.uCallbackMessage = WmTrayIcon;
        _nid.hIcon = _hIcon;
        _nid.szTip = _tooltip;
        if (!Shell_NotifyIconW(NimAdd, ref _nid))
        {
            _ = Shell_NotifyIconW(NimDelete, ref _nid);
            _ = Shell_NotifyIconW(NimAdd, ref _nid);
        }
    }

    private void FreeIcon()
    {
        if (_hIcon != IntPtr.Zero)
        {
            _ = DestroyIcon(_hIcon);
            _hIcon = IntPtr.Zero;
        }
    }

    // ---- shellapi.h / winuser.h（签名按 SDK 头文件核对；与 S6 spike 验证一致）----

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NOTIFYICONDATA
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uID;
        public uint uFlags;
        public uint uCallbackMessage;
        public IntPtr hIcon;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szTip;

        public uint dwState;
        public uint dwStateMask;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string szInfo;

        public uint uVersion;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string szInfoTitle;

        public uint dwInfoFlags;
        public Guid guidItem;
        public IntPtr hBalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NOTIFYICONIDENTIFIER
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uID;
        public Guid guidItem;
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
    private struct WNDCLASSW
    {
        public uint style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public IntPtr hInstance;
        public IntPtr hIcon;
        public IntPtr hCursor;
        public IntPtr hbrBackground;
        public string? lpszMenuName;
        public string lpszClassName;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Shell_NotifyIconW(uint dwMessage, ref NOTIFYICONDATA lpData);

    [DllImport("shell32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Shell_NotifyIconGetRect(ref NOTIFYICONIDENTIFIER identifier, out RECT iconRect);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern ushort RegisterClassW(ref WNDCLASSW lpWndClass);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowExW(
        uint dwExStyle, string lpClassName, string lpWindowName, uint dwStyle,
        int x, int y, int nWidth, int nHeight, IntPtr hWndParent, IntPtr hMenu,
        IntPtr hInstance, IntPtr lpParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr DefWindowProcW(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern uint RegisterWindowMessageW(string lpString);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr hIcon);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandleW(string? lpModuleName);
}
