// Swift 来源：无（Windows 端新增；Phase 0 spike S6 —— 托盘图标可行性 demo，计划 §9）。
//
// 验证点（S6 验收标准）：
//  1. Shell_NotifyIconW 直调（NIM_ADD / NIM_MODIFY / NIM_DELETE），P/Invoke 签名按 shellapi.h；
//  2. Explorer 重启恢复：RegisterWindowMessage("TaskbarCreated") 广播到达后重新 NIM_ADD；
//     —— 因此窗口必须是不可见的普通顶层窗口，不能用 message-only（HWND_MESSAGE 收不到广播）；
//  3. 多档 DPI：GetDpiForSystem 缩放图标尺寸（16px @96dpi 基准）；
//  4. 环形配额图标：GDI+ 画 360°*pct 圆弧，颜色分段（>50% 绿 / >20% 黄 / 其余红），限帧 1s 更新；
//  5. 左键 → 气泡通知（弹层占位），右键 → Win32 弹出菜单（退出）。
//
// demo 数据为自循环百分比（0→100→0），真实配额接入是 W1 已就位的 GlmClient 等客户端的工作。

#nullable enable

using System.Runtime.InteropServices;

namespace AIQuotaBar.TrayDemo;

internal static class Program
{
    private const uint WmApp = 0x8000;
    private const uint WmTrayIcon = WmApp + 1;          // NOTIFYICONDATA.uCallbackMessage
    private const uint WmDestroy = 0x0002;
    private const uint WmCommand = 0x0111;
    private const uint WmTimer = 0x0113;
    private const uint WmLbuttonup = 0x0202;
    private const uint WmRbuttonup = 0x0205;

    private const uint NifMessage = 0x01;
    private const uint NifIcon = 0x02;
    private const uint NifTip = 0x04;
    private const uint NifInfo = 0x10;

    private const uint NimAdd = 0;
    private const uint NimModify = 1;
    private const uint NimDelete = 2;

    private static uint _wmTaskbarCreated;
    private static IntPtr _hwnd;
    private static IntPtr _hIcon = IntPtr.Zero;
    private static int _percent = 100;
    private static NOTIFYICONDATA _nid;

    private static IntPtr WndProcDelegatePointer; // 静态委托保持存活，防止 GC 回收后回调崩溃

    public static void Main()
    {
        Console.OutputEncoding = System.Text.Encoding.UTF8;
        _wmTaskbarCreated = RegisterWindowMessageW("TaskbarCreated");

        WndProcDelegatePointer = Marshal.GetFunctionPointerForDelegate<WndProcDelegate>(WndProc);
        var wc = new WNDCLASSW
        {
            lpfnWndProc = WndProcDelegatePointer,
            lpszClassName = "AIQuotaBarTrayDemo",
            hInstance = GetModuleHandleW(null),
        };
        _ = RegisterClassW(ref wc);

        // 不可见的普通顶层窗口（WS_OVERLAPPED，永不 Show）：能收 tray 回调，也能收 TaskbarCreated 广播。
        _hwnd = CreateWindowExW(
            0, "AIQuotaBarTrayDemo", "AI Quota Bar Tray Demo", 0,
            0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);

        AddTrayIcon();
        Console.WriteLine($"[S6 demo] 托盘图标已添加（pid={Environment.ProcessId}），配额环每秒自循环更新。");
        Console.WriteLine("[S6 demo] 左键托盘 = 气泡通知（弹层占位）；右键 = 菜单（退出）。Explorer 重启后图标应自动恢复。");
        Console.WriteLine("[S6 demo] 验证 Explorer 恢复：任务管理器结束 explorer.exe 再新建 explorer.exe，看图标是否回来。");

        _ = SetTimer(_hwnd, 1, 1000, IntPtr.Zero);

        while (GetMessageW(out var msg, IntPtr.Zero, 0, 0) > 0)
        {
            TranslateMessage(ref msg);
            _ = DispatchMessageW(ref msg);
        }

        Console.WriteLine("[S6 demo] 已退出。");
    }

    private static IntPtr WndProc(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam)
    {
        if (message == _wmTaskbarCreated)
        {
            // Explorer 重启：托盘区整体重建，必须重新 NIM_ADD（S6 核心验证点）。
            Console.WriteLine($"[{DateTime.Now:HH:mm:ss}] TaskbarCreated 广播到达 → 重新注册托盘图标");
            AddTrayIcon();
        }
        else if (message == WmTrayIcon)
        {
            var mouse = unchecked((uint)(short)lParam); // lParam 低字 = 鼠标消息
            if (mouse == WmLbuttonup)
            {
                ShowBalloon("AI Quota Bar", $"左键控制中心将在此弹出（配额 {_percent}%）。S6 demo 占位。");
            }
            else if (mouse == WmRbuttonup)
            {
                ShowContextMenu();
            }
        }
        else if (message == WmTimer)
        {
            _percent -= 3;
            if (_percent < 0)
            {
                _percent = 100;
            }

            UpdateTrayIcon();
        }
        else if (message == WmCommand && LowWord(wParam) == 1)
        {
            _ = DestroyWindow(hWnd);
        }
        else if (message == WmDestroy)
        {
            _ = Shell_NotifyIconW(NimDelete, ref _nid);
            FreeIcon();
            _ = KillTimer(hWnd, 1);
            PostQuitMessage(0);
        }

        return DefWindowProcW(hWnd, message, wParam, lParam);
    }

    private delegate IntPtr WndProcDelegate(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);

    private static void AddTrayIcon()
    {
        FreeIcon();
        _hIcon = CreateRingIcon(_percent);
        _nid = default;
        _nid.cbSize = (uint)Marshal.SizeOf<NOTIFYICONDATA>();
        _nid.hWnd = _hwnd;
        _nid.uID = 1;
        _nid.uFlags = NifMessage | NifIcon | NifTip;
        _nid.uCallbackMessage = WmTrayIcon;
        _nid.hIcon = _hIcon;
        _nid.szTip = $"AI Quota Bar（demo）— {_percent}%";
        if (!Shell_NotifyIconW(NimAdd, ref _nid))
        {
            // 重启竞态下 NIM_ADD 可能因旧条目仍在返回失败：先删再加一次。
            _ = Shell_NotifyIconW(NimDelete, ref _nid);
            _ = Shell_NotifyIconW(NimAdd, ref _nid);
        }
    }

    private static void UpdateTrayIcon()
    {
        FreeIcon();
        _hIcon = CreateRingIcon(_percent);
        _nid.hIcon = _hIcon;
        _nid.uFlags = NifIcon | NifTip;
        _nid.szTip = $"AI Quota Bar（demo）— {_percent}%";
        _ = Shell_NotifyIconW(NimModify, ref _nid);
    }

    private static void ShowBalloon(string title, string text)
    {
        _nid.uFlags = NifInfo;
        _nid.szInfoTitle = title;
        _nid.szInfo = text;
        _ = Shell_NotifyIconW(NimModify, ref _nid);
    }

    /// <summary>GDI+ 画环形配额图标；尺寸按系统 DPI 缩放（16px @96dpi 基准，计划 §8 多档要求）。</summary>
    private static IntPtr CreateRingIcon(int percent)
    {
        var dpi = GetDpiForSystem();
        var size = Math.Max(16, 16 * dpi / 96);
        using var bitmap = new System.Drawing.Bitmap(size, size);
        using var g = System.Drawing.Graphics.FromImage(bitmap);
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        g.Clear(System.Drawing.Color.Transparent);

        var color = percent > 50
            ? System.Drawing.Color.FromArgb(76, 175, 80)
            : percent > 20
                ? System.Drawing.Color.FromArgb(245, 180, 40)
                : System.Drawing.Color.FromArgb(220, 60, 60);

        var thickness = Math.Max(2, size / 5);
        var rect = new System.Drawing.Rectangle(thickness / 2, thickness / 2, size - thickness, size - thickness);

        // 背景轨道（浅灰）+ 前景弧（配额剩余），从 12 点方向顺时针。
        using (var track = new System.Drawing.Pen(System.Drawing.Color.FromArgb(60, 60, 60), thickness))
        {
            g.DrawEllipse(track, rect);
        }

        using var arc = new System.Drawing.Pen(color, thickness);
        if (percent >= 100)
        {
            g.DrawEllipse(arc, rect);
        }
        else if (percent > 0)
        {
            g.DrawArc(arc, rect, -90, 360f * percent / 100f);
        }

        return bitmap.GetHicon();
    }

    private static void FreeIcon()
    {
        if (_hIcon != IntPtr.Zero)
        {
            _ = DestroyIcon(_hIcon);
            _hIcon = IntPtr.Zero;
        }
    }

    private static void ShowContextMenu()
    {
        var menu = CreatePopupMenu();
        _ = AppendMenuW(menu, 0x0000, 1, "刷新 Refresh");
        _ = AppendMenuW(menu, 0x0800 /*MF_SEPARATOR*/, 0, null);
        _ = AppendMenuW(menu, 0x0000, 2, "退出 Exit");

        // KB135788：菜单前必须 SetForegroundWindow，否则菜单不消失。
        _ = SetForegroundWindow(_hwnd);
        _ = GetCursorPos(out var pt);
        var cmd = TrackPopupMenu(menu, 0x0182 /*TPM_RIGHTBUTTON|TPM_RETURNCMD*/, pt.X, pt.Y, 0, _hwnd, IntPtr.Zero);
        _ = DestroyMenu(menu);
        if (cmd == 2)
        {
            _ = DestroyWindow(_hwnd);
        }
        else if (cmd == 1)
        {
            UpdateTrayIcon();
        }
    }

    private static uint LowWord(IntPtr wParam) => unchecked((uint)(short)(long)wParam);

    // ---- shellapi.h / winuser.h P/Invoke（签名按 Windows SDK 头文件逐字段核对）----

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
        public string szTip;              // 鼠标悬停提示

        public uint dwState;
        public uint dwStateMask;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string szInfo;             // 气泡通知正文

        public uint uVersion;             // union { uTimeout; uVersion }

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string szInfoTitle;        // 气泡通知标题

        public uint dwInfoFlags;
        public Guid guidItem;
        public IntPtr hBalloonIcon;
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

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public int ptX;
        public int ptY;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X;
        public int Y;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Shell_NotifyIconW(uint dwMessage, ref NOTIFYICONDATA lpData);

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
    private static extern int GetMessageW(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TranslateMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    private static extern IntPtr DispatchMessageW(ref MSG lpMsg);

    [DllImport("user32.dll")]
    private static extern uint RegisterWindowMessageW(string lpString);

    [DllImport("user32.dll")]
    private static extern IntPtr SetTimer(IntPtr hWnd, uint nIDEvent, uint uElapse, IntPtr lpTimerFunc);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool KillTimer(IntPtr hWnd, uint uIDEvent);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern void PostQuitMessage(int nExitCode);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForSystem();

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr hIcon);

    [DllImport("user32.dll")]
    private static extern IntPtr CreatePopupMenu();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AppendMenuW(IntPtr hMenu, uint uFlags, uint uIDNewItem, string? lpNewItem);

    [DllImport("user32.dll")]
    private static extern uint TrackPopupMenu(
        IntPtr hMenu, uint uFlags, int x, int y, int nReserved, IntPtr hWnd, IntPtr prcRect);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyMenu(IntPtr hMenu);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out POINT lpPoint);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandleW(string? lpModuleName);
}
