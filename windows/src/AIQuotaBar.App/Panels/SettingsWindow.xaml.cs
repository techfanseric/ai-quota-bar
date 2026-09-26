// Swift 来源：Settings/Panes 凭据与显示偏好的最小等价面（完整设置窗随 W2 设置页扩展）。

using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using AIQuotaBar.Platform.Credentials;

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
        ProxyBox.Text = app.Settings.ProxyUrl ?? string.Empty;
        RefreshBox.Text = app.Settings.RefreshSeconds.ToString();
    }

    private void OnNumericOnly(object sender, TextCompositionEventArgs e) =>
        e.Handled = !int.TryParse(e.Text, out _);

    private void OnSave(object sender, RoutedEventArgs e)
    {
        var app = (App)Application.Current;
        var credentials = new CredentialStore();

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

            app.Settings.ProxyUrl = string.IsNullOrWhiteSpace(ProxyBox.Text) ? null : ProxyBox.Text.Trim();
            app.Settings.RefreshSeconds = int.TryParse(RefreshBox.Text, out var seconds) && seconds >= 15
                ? seconds
                : 60;
            app.Settings.Save();

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
