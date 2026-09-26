// Swift 来源：Views 右键路由面板 —— Windows：PopupWindow 形态。
// 数据：ClashConfigurationDiscovery 找控制器，ClashApiClient 拉组快照；
// 行为：点击路由即切换（SelectRouteAsync），测速回填延迟（TestGroupAsync）。

using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using AIQuotaBar.App.Services;
using AIQuotaBar.Providers.Clash;

namespace AIQuotaBar.App.Panels;

public partial class RoutePanel : PopupWindow
{
    private List<ClashRoute> _routes = [];
    private string? _groupName;
    private bool _loading;

    public static RoutePanel Instance { get; } = new();

    private RoutePanel()
    {
        InitializeComponent();
        IsVisibleChanged += (_, e) =>
        {
            if ((bool)e.NewValue)
            {
                _ = ReloadAsync();
            }
        };
    }

    private App AppHost => (App)Application.Current;

    private async Task ReloadAsync()
    {
        if (_loading)
        {
            return;
        }

        _loading = true;
        ErrorText.Visibility = Visibility.Collapsed;
        GroupText.Text = "加载中…";
        try
        {
            var snapshot = await AppHost.Clash.LoadRoutesAsync();
            if (snapshot is null)
            {
                ErrorText.Text = AppHost.Clash.Error is null
                    ? "未发现本机 Clash 控制器（安装 Clash Verge Rev 或检查 external-controller 配置）。"
                    : $"Clash 请求失败：{AppHost.Clash.Error}";
                ErrorText.Visibility = Visibility.Visible;
                RoutesHost.Children.Clear();
                GroupText.Text = string.Empty;
                return;
            }

            _routes = [.. snapshot.Routes];
            _groupName = snapshot.GroupName;
            GroupText.Text = $"{snapshot.GroupName} · 当前 {snapshot.SelectedRouteName}";
            RebuildRoutes(snapshot.SelectedRouteName);
        }
        finally
        {
            _loading = false;
        }
    }

    private void RebuildRoutes(string? selected)
    {
        RoutesHost.Children.Clear();
        foreach (var route in _routes)
        {
            var row = new Border
            {
                CornerRadius = new System.Windows.CornerRadius(6),
                Padding = new Thickness(10, 6, 10, 6),
                Margin = new Thickness(8, 1, 8, 1),
                Background = route.Name == selected ? FindResource("HoverBrush") as Brush : Brushes.Transparent,
                Cursor = Cursors.Hand,
                Tag = route.Name,
            };
            var dock = new DockPanel();
            var mark = new TextBlock
            {
                Text = route.Name == selected ? "● " : "  ",
                Foreground = FindResource("AccentBlue") as Brush,
                FontSize = 12,
            };
            dock.Children.Add(mark);
            var delay = new TextBlock
            {
                Text = route.Delay is { } d && d > 0 ? $"{d}ms" : route.Delay == 0 ? "超时" : "—",
                HorizontalAlignment = HorizontalAlignment.Right,
                FontSize = 12,
                Foreground = FindResource("TextSecondary") as Brush,
                Tag = route.Name,
            };
            dock.Children.Add(delay);
            dock.Children.Add(new TextBlock
            {
                Text = route.Name,
                FontSize = 12,
                Foreground = FindResource("TextPrimary") as Brush,
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
            row.Child = dock;
            row.MouseLeftButtonUp += OnRouteClick;
            RoutesHost.Children.Add(row);
        }
    }

    private async void OnRouteClick(object sender, MouseButtonEventArgs e)
    {
        if (sender is not Border { Tag: string route } || _groupName is null)
        {
            return;
        }

        var ok = await AppHost.Clash.SwitchRouteAsync(route);
        if (ok)
        {
            GroupText.Text = $"{_groupName} · 当前 {route}";
            RebuildRoutes(route);
        }
        else
        {
            ErrorText.Text = $"切换失败：{AppHost.Clash.Error ?? "未知错误"}";
            ErrorText.Visibility = Visibility.Visible;
        }
    }

    private async void OnTest(object sender, RoutedEventArgs e)
    {
        if (_groupName is null)
        {
            return;
        }

        TestButton.IsEnabled = false;
        GroupText.Text = "测速中…";
        try
        {
            var delays = await AppHost.Clash.TestGroupAsync(_groupName);
            if (delays is not null)
            {
                _routes = _routes
                    .Select(r => delays.TryGetValue(r.Name, out var delay) ? r with { Delay = delay } : r)
                    .ToList();
                RebuildRoutes(_routes.FirstOrDefault(r => r.IsSelected)?.Name);
                GroupText.Text = _groupName;
            }
        }
        finally
        {
            TestButton.IsEnabled = true;
        }
    }

    private void OnReload(object sender, RoutedEventArgs e) => _ = ReloadAsync();
}
