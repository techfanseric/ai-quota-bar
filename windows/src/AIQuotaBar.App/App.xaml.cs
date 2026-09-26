// Swift 来源：无（Windows 端新增；W2 正式应用入口）。
// 对应 macOS：AIQuotaBar/App（菜单栏壳）—— Windows 形态为托盘常驻（无主窗），
// 左键托盘 = 控制中心（配额面板，QuotaPanel），右键托盘 = 路由面板（RoutePanel）。
//
// 计划 §8 验收项在入口落地：
//  - 单实例：named mutex；二次启动通过激活事件唤起既有实例（--panel=quota|route）。
//  - 生命周期：托盘删除图标后 ShutdownMode=OnExplicitShutdown 退出。

using System.IO;
using System.Text.Json;
using System.Threading;
using System.Windows;
using AIQuotaBar.App.Panels;
using AIQuotaBar.App.Services;

namespace AIQuotaBar.App;

public partial class App : Application
{
    private const string SingleInstanceMutexName = @"Local\AIQuotaBar.App.SingleInstance";
    private const string ShowQuotaEventName = @"Local\AIQuotaBar.ShowQuotaPanel";
    private const string ShowRouteEventName = @"Local\AIQuotaBar.ShowRoutePanel";

    private Mutex? _singleInstance;
    private TrayIconService? _tray;
    private QuotaService? _quota;
    private ClashService? _clash;

    public static AppSettings Settings { get; private set; } = new();

    public QuotaService Quota => _quota ?? throw new InvalidOperationException("QuotaService 未初始化");
    public ClashService Clash => _clash ?? throw new InvalidOperationException("ClashService 未初始化");

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        Settings = AppSettings.Load();
        DispatcherUnhandledException += (_, args) =>
        {
            // 顶层兜底：任何 UI 线程异常不允许闪退（托盘常驻应用的可用性底线）。
            _tray?.ShowBalloon("AI Quota Bar", $"发生异常：{args.Exception.Message}");
            args.Handled = true;
        };

        var wantPanel = ParsePanelArg(e.Args);
        _singleInstance = new Mutex(true, SingleInstanceMutexName, out var isFirst);
        if (!isFirst)
        {
            ActivateRunningInstance(wantPanel);
            Shutdown();
            return;
        }

        _quota = new QuotaService(Settings);
        _clash = new ClashService(Settings);
        _quota.StateChanged += OnQuotaStateChanged;

        _tray = new TrayIconService();
        _tray.LeftClick += () => ShowPanel(QuotaPanel.Instance);
        _tray.RightClick += () => ShowPanel(RoutePanel.Instance);
        _tray.RunIconLoop();

        StartActivationListener();
        _ = _quota.RefreshAsync();

        // 配额轮询（计划 §11：间隔可设，默认 60s；请求在 QuotaService 内合并）。
        var timer = new System.Windows.Threading.DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(Math.Max(15, Settings.RefreshSeconds)),
        };
        timer.Tick += async (_, _) => await _quota.RefreshAsync();
        timer.Start();

        if (wantPanel is { } panel)
        {
            ShowPanel(panel == "route" ? RoutePanel.Instance : QuotaPanel.Instance);
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _tray?.Dispose();
        _singleInstance?.ReleaseMutex();
        _singleInstance?.Dispose();
        base.OnExit(e);
    }

    /// <summary>面板统一入口：定位到托盘旁并打开（计划 §8：弹层按任务栏位置对齐，失焦关闭）。</summary>
    public static void ShowPanel(PopupWindow panel)
    {
        panel.PositionNearTray();
        panel.Show();
        panel.Activate();
    }

    /// <summary>托盘图标屏幕矩形（弹层定位用；服务未就绪时为 null）。</summary>
    public Rect? TrayIconRect() => _tray?.GetIconScreenRect();

    public void ExitApplication()
    {
        _tray?.RemoveIcon();
        Shutdown();
    }

    private void OnQuotaStateChanged()
    {
        var summary = _quota?.TraySummary ?? "AI Quota Bar";
        var percent = _quota?.RingPercent;
        _tray?.UpdateState(percent, summary);
    }

    private static string? ParsePanelArg(string[] args)
    {
        for (var i = 0; i < args.Length; i++)
        {
            if (args[i] == "--panel" && i + 1 < args.Length && args[i + 1] is "quota" or "route")
            {
                return args[i + 1];
            }

            if (args[i].StartsWith("--panel=", StringComparison.Ordinal))
            {
                var value = args[i]["--panel=".Length..];
                return value is "quota" or "route" ? value : null;
            }
        }

        return null;
    }

    private static void ActivateRunningInstance(string? wantPanel)
    {
        // 二次启动激活：通过命名事件通知首实例（比广播窗口消息简单且无需窗口句柄协商）。
        if (wantPanel == "route")
        {
            if (EventWaitHandle.TryOpenExisting(ShowRouteEventName, out var route))
            {
                route.Set();
                route.Dispose();
            }
        }
        else
        {
            if (EventWaitHandle.TryOpenExisting(ShowQuotaEventName, out var quota))
            {
                quota.Set();
                quota.Dispose();
            }
        }
    }

    private void StartActivationListener()
    {
        // 后台线程等待激活事件，转发回 UI 线程打开面板。
        var quotaEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowQuotaEventName);
        var routeEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowRouteEventName);
        var listener = new Thread(() =>
        {
            while (true)
            {
                var index = WaitHandle.WaitAny(new WaitHandle[] { quotaEvent, routeEvent });
                Dispatcher.BeginInvoke(index == 0
                    ? (Action)(() => ShowPanel(QuotaPanel.Instance))
                    : () => ShowPanel(RoutePanel.Instance));
            }
        })
        {
            IsBackground = true,
            Name = "AIQuotaBar.ActivationListener",
        };
        listener.Start();
    }
}

/// <summary>用户级设置（计划 §4：UserDefaults → %APPDATA%\AIQuotaBar\settings.json，不用注册表存业务配置）。</summary>
public sealed class AppSettings
{
    public string? ProxyUrl { get; set; }

    public int RefreshSeconds { get; set; } = 60;

    public static AppSettings Load()
    {
        try
        {
            var path = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "AIQuotaBar", "settings.json");
            if (File.Exists(path))
            {
                return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path)) ?? new AppSettings();
            }
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        {
            // 设置损坏时回落默认值，不让常驻应用起不来。
        }

        return new AppSettings();
    }

    public void Save()
    {
        var dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "AIQuotaBar");
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, "settings.json"), JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
    }

    public HttpClientHandler CreateHttpHandler()
    {
        var handler = new HttpClientHandler();
        if (!string.IsNullOrWhiteSpace(ProxyUrl)
            && Uri.TryCreate(ProxyUrl, UriKind.Absolute, out var proxy))
        {
            handler.Proxy = new System.Net.WebProxy(proxy);
            handler.UseProxy = true;
        }

        return handler;
    }
}
