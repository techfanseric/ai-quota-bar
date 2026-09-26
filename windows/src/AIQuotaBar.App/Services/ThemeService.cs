// Swift 来源：无（Windows 端新增；亮/暗双主题运行时切换服务）。
// 对应 macOS：SwiftUI .preferredColorScheme —— Windows 原生表达：
//  - WPF 无内置主题引擎，以「主题字典整本互换 + DynamicResource」实现运行时切换
//    （App.xaml.MergedDictionaries[0] 固定为主题字典位，见 App.xaml 注释）；
//  - 三态偏好 ThemePreference（跟随系统/亮/暗）持久化于 AppSettings.Theme（旧 settings.json
//    缺字段 → null → FollowSystem，天然向后兼容）；
//  - 系统主题跟随：HKCU\...\Themes\Personalize 的 AppsUseLightTheme（1=亮 0=暗），
//    变更监听用 P/Invoke RegNotifyChangeKeyValue（advapi32，仓库 TrayIconService/PopupWindow
//    的 P/Invoke 风格：私有 delegate/DllImport 区块 + 常量名）——Microsoft.Win32 无托管变更事件，
//    轮询被否（延迟与空转），WMI 过重；
//  - 系统强调色：HKCU\Software\Microsoft\Windows\DWM 的 ColorizationColor（REG_DWORD，
//    0xAABBGGRR 布局）→ AccentBrush/AccentHoverBrush（hover 按主题向白/向黑派生），
//    读失败回退主题字典各自兜底色（暗 #4C9EE8 / 亮 #005FB8）。

using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using Application = System.Windows.Application;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

namespace AIQuotaBar.App.Services;

/// <summary>用户主题偏好（持久化字符串与枚举名一致；未知/缺失值一律回落跟随系统）。</summary>
public enum ThemePreference
{
    FollowSystem,
    Light,
    Dark,
}

/// <summary>实际生效主题（跟随模式下由系统 AppsUseLightTheme 推导）。</summary>
public enum EffectiveTheme
{
    Light,
    Dark,
}

public sealed class ThemeService : IDisposable
{
    private const string PersonalizeKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
    private const string AppsUseLightThemeValue = "AppsUseLightTheme";
    private const string DwmKeyPath = @"Software\Microsoft\Windows\DWM";
    private const string ColorizationColorValue = "ColorizationColor";
    private const int RegNotifyChangeLastSet = 0x00000001;

    /// <summary>本程序集名（App csproj AssemblyName=AIQuotaBar，主题字典 pack URI 用）。</summary>
    private const string ThemeAssemblyName = "AIQuotaBar";

    private const uint DarkAcrylicGradient = 0xCC202020; // AARRGGBB，W2 暗色基线
    private const uint LightAcrylicGradient = 0xCCF3F3F3;

    /// <summary>跟随模式下系统亮暗切换的即时通知（UI 线程回调；字典已换完）。</summary>
    public event Action? ThemeChanged;

    public static ThemeService Instance { get; private set; } = new();

    public ThemePreference Preference { get; private set; } = ThemePreference.FollowSystem;

    public EffectiveTheme Current { get; private set; } = EffectiveTheme.Dark;

    /// <summary>弹层亚克力底色（AARRGGBB）：PopupWindow.ApplyAcrylic 取值，主题切换后已开窗口由
    /// ThemeChanged 回调重刷（即便不刷，窗口下次 Show 也会重新取值生效）。</summary>
    public uint PopupAcrylicGradient => Current == EffectiveTheme.Dark ? DarkAcrylicGradient : LightAcrylicGradient;

    private RegistryKey? _personalizeKey;
    private AutoResetEvent? _changeSignal;
    private Thread? _watchThread;
    private bool _appliedOnce;
    private volatile bool _disposed;

    private ThemeService()
    {
    }

    /// <summary>App 启动时初始化（UI 线程）：应用持久化偏好并启动系统主题监听。</summary>
    public static void Initialize(ThemePreference preference)
    {
        Instance.ApplyPreference(preference);
        Instance.StartSystemWatcher();
    }

    /// <summary>设置窗三选即时生效入口；持久化由调用方（SettingsWindow.OnSave → AppSettings）负责。</summary>
    public void ApplyPreference(ThemePreference preference)
    {
        Preference = preference;
        ApplyEffective();
    }

    /// <summary>settings.json 字符串 → 偏好（null/未知值回退跟随系统，向后兼容旧文件）。</summary>
    public static ThemePreference ParsePreference(string? value) => value switch
    {
        nameof(ThemePreference.Light) => ThemePreference.Light,
        nameof(ThemePreference.Dark) => ThemePreference.Dark,
        _ => ThemePreference.FollowSystem,
    };

    /// <summary>读系统应用主题（AppsUseLightTheme：1=亮 0=暗；键缺失/不可读按亮色——Win10 默认）。</summary>
    public static EffectiveTheme ReadSystemTheme()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(PersonalizeKeyPath);
            // REG_DWORD 装箱为 int；仅 0 显式表示暗色，缺失/非数值一律亮色。
            return key?.GetValue(AppsUseLightThemeValue) is int value && value == 0
                ? EffectiveTheme.Dark
                : EffectiveTheme.Light;
        }
        catch (Exception ex)
        {
            // 注册表读失败（权限/特殊会话）：不崩常驻应用，保守按暗色（当前视觉基线）。
            App.Log($"theme: read system theme failed: {ex.Message}");
            return EffectiveTheme.Dark;
        }
    }

    private void ApplyEffective()
    {
        var effective = Preference switch
        {
            ThemePreference.Light => EffectiveTheme.Light,
            ThemePreference.Dark => EffectiveTheme.Dark,
            _ => ReadSystemTheme(),
        };
        if (effective == Current && _appliedOnce)
        {
            return; // 幂等：重复应用（如注册表监听重复触发）直接跳过。
        }

        _appliedOnce = true;
        Current = effective;
        SwapThemeDictionary(effective);
        ApplySystemAccent();
        ThemeChanged?.Invoke();
    }

    /// <summary>主题字典互换：MergedDictionaries[0] 是主题字典位（App.xaml 注释锁定该契约）。
    /// 面板/控件一律 DynamicResource 取键，替换字典即全 UI 生效。
    /// Source 用「程序集名 + ;component」全限定 pack URI（App 的 AssemblyName=AIQuotaBar，
    /// 无限定的 application origin 形式在非入口程序集上下文解析不到资源）。</summary>
    private static void SwapThemeDictionary(EffectiveTheme theme)
    {
        var merged = Application.Current.Resources.MergedDictionaries;
        var source = new Uri($"pack://application:,,,/{ThemeAssemblyName};component/Panels/Themes/{theme}.xaml");
        if (merged.Count == 0)
        {
            merged.Add(new ResourceDictionary { Source = source });
            return;
        }

        merged[0] = new ResourceDictionary { Source = source };
    }

    /// <summary>读 DWM ColorizationColor 覆盖 AccentBrush/AccentHoverBrush（写入 Application.Resources
    /// 顶层，优先级高于合并字典内的兜底值）；hover 暗色向白、亮色向黑各 25% 派生。</summary>
    private void ApplySystemAccent()
    {
        var accent = ReadSystemAccentColor();
        var hover = Current == EffectiveTheme.Dark
            ? Lerp(accent, Colors.White, 0.25)
            : Lerp(accent, Colors.Black, 0.25);
        var resources = Application.Current.Resources;
        resources["AccentBrush"] = new SolidColorBrush(accent);
        resources["AccentHoverBrush"] = new SolidColorBrush(hover);
    }

    /// <summary>DWM ColorizationColor（0xAABBGGRR 布局的 REG_DWORD）→ WPF Color；
    /// 失败/缺失回退当前主题字典兜底色（暗 #4C9EE8 / 亮 #005FB8）。</summary>
    private Color ReadSystemAccentColor()
    {
        var fallback = (Color)ColorConverter.ConvertFromString(
            Current == EffectiveTheme.Dark ? "#4C9EE8" : "#005FB8");
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(DwmKeyPath);
            if (key?.GetValue(ColorizationColorValue) is int raw)
            {
                var value = unchecked((uint)raw);
                return Color.FromRgb((byte)(value & 0xFF), (byte)((value >> 8) & 0xFF), (byte)((value >> 16) & 0xFF));
            }
        }
        catch (Exception ex)
        {
            App.Log($"theme: read accent color failed: {ex.Message}");
        }

        return fallback;
    }

    private static Color Lerp(Color from, Color to, double t) => Color.FromRgb(
        (byte)(from.R + (to.R - from.R) * t),
        (byte)(from.G + (to.G - from.G) * t),
        (byte)(from.B + (to.B - from.B) * t));

    // ---- 系统主题监听（RegNotifyChangeKeyValue 异步通知 + 常驻等待线程，App 激活监听同款形态）----

    private void StartSystemWatcher()
    {
        try
        {
            // 监听期间键句柄必须保持打开（关闭即取消通知），服务生命周期内不释放。
            _personalizeKey = Registry.CurrentUser.OpenSubKey(PersonalizeKeyPath);
            if (_personalizeKey is null)
            {
                App.Log("theme: Personalize key missing, system watcher disabled");
                return;
            }

            _changeSignal = new AutoResetEvent(false);
            _watchThread = new Thread(WatchLoop)
            {
                IsBackground = true,
                Name = "AIQuotaBar.ThemeWatcher",
            };
            _watchThread.Start();
        }
        catch (Exception ex)
        {
            App.Log($"theme: watcher start failed ({ex.Message}), manual switch still works");
        }
    }

    private void WatchLoop()
    {
        var keyHandle = _personalizeKey!.Handle;
        var eventHandle = _changeSignal!.SafeWaitHandle.DangerousGetHandle();
        while (!_disposed)
        {
            _changeSignal.Reset();
            // 异步形态：立即返回，注册表值变化时置位事件；每次触发后需重新布防。
            var result = RegNotifyChangeKeyValue(keyHandle, watchSubtree: false, RegNotifyChangeLastSet, eventHandle, fAsynchronous: true);
            if (result != 0)
            {
                App.Log($"theme: RegNotifyChangeKeyValue failed={result}, watcher stopped");
                return;
            }

            if (_changeSignal.WaitOne() && !_disposed)
            {
                // 回 UI 线程换字典（跟随模式才响应；手动模式下布防继续但应用空转，切回跟随即恢复）。
                Application.Current?.Dispatcher.BeginInvoke(() =>
                {
                    if (Preference == ThemePreference.FollowSystem)
                    {
                        ApplyEffective();
                    }
                });
            }
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _changeSignal?.Set(); // 唤醒等待线程使其观察 _disposed 退出
        _changeSignal?.Dispose();
        _personalizeKey?.Dispose();
    }

    // ---- P/Invoke（advapi32；风格对齐 PopupWindow.SetWindowCompositionAttribute）----

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern int RegNotifyChangeKeyValue(
        SafeRegistryHandle hKey,
        bool watchSubtree,
        int dwNotifyFilter,
        IntPtr hEvent,
        bool fAsynchronous);
}
