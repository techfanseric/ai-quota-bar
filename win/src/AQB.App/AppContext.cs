using AQB.Core;
using AQB.Settings;

namespace AQB.App;

/// <summary>Tray host: notify icon, menus, popup lifecycle, single instance.</summary>
internal sealed class TrayHost : ApplicationContext
{
    private readonly AppSettings _settings;
    private readonly CredentialVault _vault;
    private readonly QuotaOrchestrator _orchestrator;
    private readonly BackgroundServices _background;
    private readonly FollowRunningAppsService _followApps;
    private readonly NotifyIcon _notifyIcon;
    private readonly System.Windows.Forms.Timer _iconTimer = new() { Interval = 30_000 };
    private readonly Mutex _singleInstanceMutex;
    private ControlCenterForm? _controlCenter;
    private ClashPanelForm? _clashPanel;
    private ConnectionsForm? _connectionsPanel;

    public TrayHost(AppSettings settings, CredentialVault vault, QuotaOrchestrator orchestrator, FollowRunningAppsService followApps, BackgroundServices background)
    {
        _settings = settings;
        _vault = vault;
        _orchestrator = orchestrator;
        _followApps = followApps;
        _background = background;

        _singleInstanceMutex = new Mutex(true, "AIQuotaBar.Win.SingleInstance", out var createdNew);
        if (!createdNew)
        {
            AppLog.Warn("Another instance is already running; exiting.");
            ExitThread();
            return;
        }

        ProgramSettings.Current = settings;

        var menu = new ContextMenuStrip();
        menu.Items.Add("Control center", null, (_, _) => ShowControlCenter());
        menu.Items.Add("Clash routes", null, (_, _) => ShowClashPanel());
        menu.Items.Add("Connections", null, (_, _) => ShowConnectionsPanel());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Refresh now", null, (_, _) => _ = _orchestrator.RefreshAsync(CancellationToken.None));
        menu.Items.Add("Settings", null, (_, _) => ShowSettings());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit AI Quota Bar", null, (_, _) => ExitThread());

        _notifyIcon = new NotifyIcon
        {
            Text = "AI Quota Bar",
            Icon = System.Drawing.SystemIcons.Application,
            ContextMenuStrip = menu,
            Visible = true,
        };
        _notifyIcon.MouseClick += (_, e) =>
        {
            if (e.Button == MouseButtons.Left)
            {
                ShowControlCenter();
            }
        };

        _orchestrator.SnapshotsChanged += OnSnapshotsChanged;
        _iconTimer.Tick += (_, _) => UpdateTrayIcon();
        _iconTimer.Start();
        _orchestrator.Start();
        UpdateTrayIcon();
        AppLog.Info("Tray host started.");
    }

    public HostState State => _background.State;

    public QuotaOrchestrator Orchestrator => _orchestrator;

    public BackgroundServices Background => _background;

    public ClashHost Clash => _background.Clash;

    public AppSettings Settings => _settings;

    private void OnSnapshotsChanged()
    {
        var menu = _notifyIcon.ContextMenuStrip;
        if (menu is { IsDisposed: false })
        {
            menu.BeginInvoke(UpdateTrayIcon);
        }
    }

    private void UpdateTrayIcon()
    {
        try
        {
            var snapshots = _orchestrator.Latest;
            if (_settings.MenuBarAppearance == "compactRing")
            {
                using var bitmap = TrayIconRenderer.RenderCompactRing(snapshots);
                SetIconFromBitmap(bitmap);
                _notifyIcon.Text = TrayIconRenderer.BuildDetailedText(snapshots);
            }
            else
            {
                // Detailed text mode: render the text into the icon bitmap.
                using var bitmap = RenderTextIcon(TrayIconRenderer.BuildDetailedText(snapshots));
                SetIconFromBitmap(bitmap);
                _notifyIcon.Text = "AI Quota Bar — " + TrayIconRenderer.BuildDetailedText(snapshots);
            }
        }
        catch (Exception e)
        {
            AppLog.Warn("Tray icon render failed: " + e.Message);
        }
    }

    private IntPtr _iconHandle;

    private void SetIconFromBitmap(Bitmap bitmap)
    {
        var previous = _iconHandle;
        _iconHandle = bitmap.GetHicon();
        _notifyIcon.Icon = Icon.FromHandle(_iconHandle);
        if (previous != IntPtr.Zero)
        {
            NativeIcon.DestroyIcon(previous);
        }
    }

    private static Bitmap RenderTextIcon(string text)
    {
        var bitmap = new Bitmap(32, 32);
        using var g = Graphics.FromImage(bitmap);
        g.Clear(Color.Transparent);
        using var font = new Font("Consolas", text.Length > 12 ? 7.5f : 9f, FontStyle.Bold, GraphicsUnit.Pixel);
        using var brush = new SolidBrush(Color.White);
        var size = g.MeasureString(text, font);
        g.DrawString(text, font, brush, (32 - size.Width) / 2f, (32 - size.Height) / 2f);
        return bitmap;
    }

    private void ShowControlCenter()
    {
        if (_controlCenter is { IsDisposed: false })
        {
            // Second left-click toggles the flyout closed, matching the macOS menu bar.
            _controlCenter.Close();
            return;
        }

        _controlCenter = new ControlCenterForm(
            _orchestrator,
            ShowSettings,
            ShowClashPanel,
            ShowConnectionsPanel,
            () => _background.State);
        _controlCenter.Show();
    }

    private void ShowClashPanel()
    {
        if (_clashPanel is { IsDisposed: false })
        {
            _clashPanel.Activate();
            return;
        }

        _clashPanel = new ClashPanelForm(ClashPanelAdapterResolver.Resolve(this));
        _clashPanel.Show();
    }

    private void ShowConnectionsPanel()
    {
        if (_connectionsPanel is { IsDisposed: false })
        {
            _connectionsPanel.Activate();
            return;
        }

        _connectionsPanel = new ConnectionsForm(ConnectionViewAdapterResolver.Resolve(this));
        _connectionsPanel.Show();
    }

    private void ShowSettings()
    {
        using var form = new SettingsForm(_settings, _vault, () =>
        {
            _background.ApplySettings();
            _ = _orchestrator.RefreshAsync(CancellationToken.None);
            AppLog.Info("Settings applied.");
        });
        form.ShowDialog(_notifyIcon.ContextMenuStrip!);
    }

    protected override void ExitThreadCore()
    {
        AppLog.Info("Tray host exiting.");
        _iconTimer.Stop();
        _orchestrator.SnapshotsChanged -= OnSnapshotsChanged;
        _followApps.Dispose();
        _orchestrator.Dispose();
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
        _singleInstanceMutex.ReleaseMutex();
        _singleInstanceMutex.Dispose();
        base.ExitThreadCore();
    }

    private static class NativeIcon
    {
        [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
        public static extern bool DestroyIcon(IntPtr hIcon);
    }
}
