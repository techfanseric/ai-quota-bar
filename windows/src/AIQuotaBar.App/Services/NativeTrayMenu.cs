// Windows 原生托盘命令菜单。刻意使用 TrackPopupMenuEx 而非自绘 WPF 弹层：系统负责字体、
// 行高、键盘助记、勾选、禁用态、亮暗主题、缩放与辅助功能；应用只提供短命令层级。

using System.Runtime.InteropServices;

namespace AIQuotaBar.App.Services;

public enum TrayMenuCommand : uint
{
    None = 0,
    OpenQuota = 1001,
    OpenRoutes = 1002,
    Refresh = 1003,
    Settings = 1004,
    ToggleAutostart = 1005,
    ThemeFollowSystem = 1101,
    ThemeLight = 1102,
    ThemeDark = 1103,
    Exit = 1099,
}

public readonly record struct TrayMenuState(
    bool IsRefreshing,
    bool AutostartEnabled,
    ThemePreference ThemePreference);

public static class NativeTrayMenu
{
    private const uint MfString = 0x0000;
    private const uint MfPopup = 0x0010;
    private const uint MfSeparator = 0x0800;
    private const uint MfChecked = 0x0008;
    private const uint MfDisabled = 0x0002;
    private const uint TpmRightButton = 0x0002;
    private const uint TpmReturnCmd = 0x0100;

    public static TrayMenuCommand Show(IntPtr owner, TrayMenuState state)
    {
        var menu = CreatePopupMenu();
        var themeMenu = CreatePopupMenu();
        if (menu == IntPtr.Zero || themeMenu == IntPtr.Zero)
        {
            if (menu != IntPtr.Zero)
            {
                _ = DestroyMenu(menu);
            }

            if (themeMenu != IntPtr.Zero)
            {
                _ = DestroyMenu(themeMenu);
            }

            return TrayMenuCommand.None;
        }

        try
        {
            AppendCommand(menu, TrayMenuCommand.OpenQuota, Lang.Get(AppStrings.TrayOpenQuota));
            AppendCommand(menu, TrayMenuCommand.OpenRoutes, Lang.Get(AppStrings.TrayOpenRoutes));
            AppendSeparator(menu);
            AppendCommand(menu, TrayMenuCommand.Refresh,
                Lang.Get(state.IsRefreshing ? AppStrings.Refreshing : AppStrings.TrayRefreshNow), state.IsRefreshing);
            AppendSeparator(menu);

            AppendCommand(themeMenu, TrayMenuCommand.ThemeFollowSystem, Lang.Get(AppStrings.ThemeFollow), false,
                state.ThemePreference == ThemePreference.FollowSystem);
            AppendCommand(themeMenu, TrayMenuCommand.ThemeLight, Lang.Get(AppStrings.ThemeLight), false,
                state.ThemePreference == ThemePreference.Light);
            AppendCommand(themeMenu, TrayMenuCommand.ThemeDark, Lang.Get(AppStrings.ThemeDark), false,
                state.ThemePreference == ThemePreference.Dark);
            _ = AppendMenuW(menu, MfPopup, unchecked((nuint)themeMenu.ToInt64()), Lang.Get(AppStrings.ThemeLabel));

            AppendCommand(menu, TrayMenuCommand.ToggleAutostart, Lang.Get(AppStrings.TrayLaunchAtLogin), false,
                state.AutostartEnabled);
            AppendCommand(menu, TrayMenuCommand.Settings, Lang.Get(AppStrings.TraySettings));
            AppendSeparator(menu);
            AppendCommand(menu, TrayMenuCommand.Exit, Lang.Get(AppStrings.TrayExit));

            _ = SetMenuDefaultItem(menu, (uint)TrayMenuCommand.OpenQuota, false);
            _ = GetCursorPos(out var point);
            _ = SetForegroundWindow(owner);
            var command = TrackPopupMenuEx(
                menu,
                TpmRightButton | TpmReturnCmd,
                point.X,
                point.Y,
                owner,
                IntPtr.Zero);
            _ = PostMessageW(owner, 0, IntPtr.Zero, IntPtr.Zero);
            return Enum.IsDefined(typeof(TrayMenuCommand), command)
                ? (TrayMenuCommand)command
                : TrayMenuCommand.None;
        }
        finally
        {
            // DestroyMenu 会递归销毁已附加的 themeMenu。
            _ = DestroyMenu(menu);
        }
    }

    private static void AppendCommand(
        IntPtr menu,
        TrayMenuCommand command,
        string label,
        bool disabled = false,
        bool isChecked = false)
    {
        var flags = MfString | (disabled ? MfDisabled : 0) | (isChecked ? MfChecked : 0);
        _ = AppendMenuW(menu, flags, (nuint)(uint)command, label);
    }

    private static void AppendSeparator(IntPtr menu) => _ = AppendMenuW(menu, MfSeparator, 0, null);

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr CreatePopupMenu();

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AppendMenuW(IntPtr menu, uint flags, nuint idOrSubmenu, string? label);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyMenu(IntPtr menu);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint TrackPopupMenuEx(
        IntPtr menu,
        uint flags,
        int x,
        int y,
        IntPtr owner,
        IntPtr parameters);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out POINT point);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostMessageW(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetMenuDefaultItem(IntPtr menu, uint item, bool byPosition);
}
