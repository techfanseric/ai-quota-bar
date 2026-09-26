// Swift 来源：Settings/Panes 凭据与显示偏好的最小等价面（完整设置窗随 W2 设置页扩展）。
// 开机自启项：Swift 端 SMAppService → Windows 端 RegistryAutostart（HKCU Run 键，
// Platform/Startup；勾选写入「可执行文件路径 + --hidden」，--hidden 由 App 入口解析为静默启动）。

using System.Windows;
using Application = System.Windows.Application;
using System.Windows.Controls;
using System.Windows.Input;
using AIQuotaBar.App.Services;
using AIQuotaBar.Platform.Credentials;
using AIQuotaBar.Platform.Startup;

namespace AIQuotaBar.App.Panels;

public partial class SettingsWindow : Window
{
    private static SettingsWindow? _open;

    public static void OpenOwned(Window? owner)
    {
        if (_open is { } existing)
        {
            existing.Activate();
            return;
        }

        _open = new SettingsWindow { Owner = owner };
        _open.Closed += (_, _) => _open = null;
        _open.Show();
    }

    public SettingsWindow()
    {
        InitializeComponent();
        var app = (App)Application.Current;
        var credentials = new CredentialStore();
        GlmBox.Text = credentials.Read("glm", string.Empty) ?? string.Empty;
        MinimaxBox.Password = credentials.Read("minimax", string.Empty) ?? string.Empty;
        ProxyBox.Text = App.Settings.ProxyUrl ?? string.Empty;
        RefreshBox.Text = App.Settings.RefreshSeconds.ToString();
        // 初始勾选态从持久化偏好恢复；Checked 事件（XAML 已挂）随之触发一次
        // ApplyPreference——同值幂等（ThemeService.ApplyEffective 短路），无副作用。
        var preference = ThemeService.ParsePreference(App.Settings.Theme);
        (preference switch
        {
            ThemePreference.Light => ThemeLightRadio,
            ThemePreference.Dark => ThemeDarkRadio,
            _ => ThemeFollowRadio,
        }).IsChecked = true;
        InitializeAutostart();
    }

    /// <summary>当前三选选中态 → 偏好（未选中任何项按跟随系统，防御半初始化态）。</summary>
    private ThemePreference SelectedThemePreference() => ThemeLightRadio.IsChecked == true
        ? ThemePreference.Light
        : ThemeDarkRadio.IsChecked == true ? ThemePreference.Dark : ThemePreference.FollowSystem;

    /// <summary>主题三选即时生效（规格 §3）；持久化随保存按钮统一落盘（OnSave）。</summary>
    private void OnThemePreferenceChecked(object sender, RoutedEventArgs e) =>
        ThemeService.Instance.ApplyPreference(SelectedThemePreference());

    /// <summary>
    /// 开机自启勾选态初始化：以 HKCU Run 键现值为准（RegistryAutostart 只读探测，无副作用）。
    /// <see cref="Environment.ProcessPath"/> 为 null（无法构造自启动命令行）时禁用控件并在状态栏提示。
    /// </summary>
    private void InitializeAutostart()
    {
        if (Environment.ProcessPath is null)
        {
            AutostartCheck.IsEnabled = false;
            StatusText.Text = "开机自启不可用：安装路径不可用。";
            return;
        }

        AutostartCheck.IsChecked = new RegistryAutostart().TryGetEnabledCommand(out _);
    }

    /// <summary>
    /// 保存时统一落自启动（与本窗体保存按钮语义一致）：勾选态与 Run 键现值不一致才写，
    /// 命令行固定为「可执行文件路径 + --hidden」（静默启动，不弹面板）。
    /// 注册表写入失败（Win32Exception 透传到本层）：状态栏显示原因、不崩溃，并中止本次保存。
    /// </summary>
    /// <returns>自启动已落定（或无需变更）返回 true；写入失败返回 false（状态栏已显示原因）。</returns>
    private bool ApplyAutostart()
    {
        if (!AutostartCheck.IsEnabled)
        {
            // 安装路径不可用：控件已禁用、无法勾选，视为无操作，不阻塞其余设置的保存。
            return true;
        }

        try
        {
            var autostart = new RegistryAutostart();
            var enabled = autostart.TryGetEnabledCommand(out _);
            if (AutostartCheck.IsChecked == true && !enabled)
            {
                autostart.Enable($"\"{Environment.ProcessPath}\" --hidden");
            }
            else if (AutostartCheck.IsChecked != true && enabled)
            {
                autostart.Disable();
            }

            return true;
        }
        catch (Exception ex)
        {
            // 透传策略的 UI 端兜底：底层异常原样展示原因（Win32Exception 等），不包装不吞。
            StatusText.Text = $"开机自启设置失败：{ex.Message}";
            return false;
        }
    }

    private void OnNumericOnly(object sender, TextCompositionEventArgs e) =>
        e.Handled = !int.TryParse(e.Text, out _);

    private void OnSave(object sender, RoutedEventArgs e)
    {
        var app = (App)Application.Current;
        var credentials = new CredentialStore();

        if (!ApplyAutostart())
        {
            return;
        }

        try
        {
            if (!string.IsNullOrWhiteSpace(GlmBox.Text))
            {
                credentials.Write("glm", string.Empty, GlmBox.Text.Trim());
            }
            else
            {
                credentials.Delete("glm", string.Empty);
            }

            if (!string.IsNullOrWhiteSpace(MinimaxBox.Password))
            {
                credentials.Write("minimax", string.Empty, MinimaxBox.Password.Trim());
            }
            else
            {
                credentials.Delete("minimax", string.Empty);
            }

            App.Settings.ProxyUrl = string.IsNullOrWhiteSpace(ProxyBox.Text) ? null : ProxyBox.Text.Trim();
            App.Settings.RefreshSeconds = int.TryParse(RefreshBox.Text, out var seconds) && seconds >= 15
                ? seconds
                : 60;
            App.Settings.Theme = SelectedThemePreference().ToString();
            App.Settings.Save();

            StatusText.Text = $"已保存（{DateTime.Now:HH:mm:ss}）。切换到控制中心点「刷新」立即生效。";
            _ = app.Quota.RefreshAsync();
        }
        catch (Exception ex)
        {
            StatusText.Text = $"保存失败：{ex.Message}";
        }
    }

    private void OnClose(object sender, RoutedEventArgs e) => Close();
}
