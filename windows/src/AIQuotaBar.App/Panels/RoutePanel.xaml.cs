// Swift 来源：Views 右键路由面板 —— Windows：PopupWindow 形态。
// 数据：ClashConfigurationDiscovery 找控制器，ClashApiClient 拉组快照；
// 行为：点击路由即切换（SelectRouteAsync），测速回填延迟（TestGroupAsync）。
// 视觉（规格 §2 原生设计）：延迟徽章胶囊（<200 绿 / <500 黄 / 其余红，超时红、未测灰）、
// 当前选中行左侧 3px 强调色竖条、测速中行内 IsIndeterminate 细条动画。

using System.Windows;
using Brush = System.Windows.Media.Brush;
using Application = System.Windows.Application;
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
    private string? _selectedRoute;
    private bool _loading;
    private bool _testing;

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
        // 主题切换时重建行（徽章/竖条画刷重新解析）；亚克力底色由 PopupWindow 基类处理。
        ThemeService.Instance.ThemeChanged += () =>
        {
            if (IsVisible)
            {
                RebuildRoutes(_routes.FirstOrDefault(static r => r.IsSelected)?.Name);
            }
        };
        // 语言切换时刷新静态文案、组头与延迟徽章（模式对齐主题切换；单例常驻，无需退订）。
        LanguageService.Instance.LanguageChanged += () =>
        {
            ApplyStrings();
            if (!IsVisible)
            {
                return;
            }

            GroupText.Text = _testing ? Lang.Get(AppStrings.Testing) : GroupHeaderText();
            RebuildRoutes(_selectedRoute ?? _routes.FirstOrDefault(static r => r.IsSelected)?.Name);
        };
        ApplyStrings();
    }

    private App AppHost => (App)Application.Current;

    /// <summary>XAML 静态文案（标题/按钮）按当前语言填充。</summary>
    private void ApplyStrings()
    {
        Title = Lang.Get(AppStrings.RoutePanelTitle);
        ClashTitleText.Text = Lang.Get(AppStrings.ClashRoutesTitle);
        TestButton.Content = Lang.Get(AppStrings.TestButton);
        ReloadButton.Content = Lang.Get(AppStrings.Refresh);
    }

    /// <summary>组头文案：无选中路由时仅组名（对齐测速完成后的既有形态）。</summary>
    private string GroupHeaderText() => _selectedRoute is { } selected
        ? Lang.Format(AppStrings.GroupCurrentFormat, _groupName, selected)
        : _groupName ?? string.Empty;

    private async Task ReloadAsync()
    {
        if (_loading)
        {
            return;
        }

        _loading = true;
        ErrorText.Visibility = Visibility.Collapsed;
        GroupText.Text = Lang.Get(AppStrings.Loading);
        try
        {
            var snapshot = await AppHost.Clash.LoadRoutesAsync();
            if (snapshot is null)
            {
                // 错误映射（关键改进）：按异常类型给出可操作双语提示，而非裸英文技术消息；
                // 无异常信息的空快照仍保留控制器缺失提示。
                ErrorText.Text = AppHost.Clash.LastException is null && AppHost.Clash.Error is null
                    ? Lang.Get(AppStrings.ControllerNotFound)
                    : DescribeClashFailure();
                ErrorText.Visibility = Visibility.Visible;
                RoutesHost.Children.Clear();
                GroupText.Text = string.Empty;
                return;
            }

            _routes = [.. snapshot.Routes];
            _groupName = snapshot.GroupName;
            _selectedRoute = snapshot.SelectedRouteName;
            GroupText.Text = GroupHeaderText();
            RebuildRoutes(snapshot.SelectedRouteName);
        }
        finally
        {
            _loading = false;
        }
    }

    /// <summary>当前 Clash 失败的本地化描述（异常类型驱动映射，见 ClashErrorText）。</summary>
    private string DescribeClashFailure() =>
        AppHost.Clash.LastException is { } error
            ? ClashErrorText.Describe(error)
            : AppHost.Clash.Error is { } message
                ? Lang.Format(AppStrings.ClashRequestFailedFormat, message)
                : Lang.Get(AppStrings.UnknownError);

    private void RebuildRoutes(string? selected)
    {
        RoutesHost.Children.Clear();
        foreach (var route in _routes)
        {
            RoutesHost.Children.Add(BuildRouteRow(route, route.Name == selected));
        }
    }

    /// <summary>路由行：左侧选中竖条（仅选中行）+ 线路名 + 右侧延迟徽章/测速动画。</summary>
    private Border BuildRouteRow(ClashRoute route, bool isSelected)
    {
        var row = new Border
        {
            Style = FindResource("RouteRowStyle") as Style,
            CornerRadius = new CornerRadius(6),
            Margin = new Thickness(8, 1, 8, 1),
            Cursor = Cursors.Hand,
            Tag = route.Name,
        };
        // 选中行底色走本地值（优先级高于样式触发器）；未选中行留给 hover 触发器。
        if (isSelected)
        {
            row.Background = FindResource("HoverBrush") as Brush;
        }

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        // 当前选中行左侧 3px 强调色竖条：内缩 5/6px 避让行的 6px 圆角（不被直角裁切）。
        if (isSelected)
        {
            var bar = new System.Windows.Shapes.Rectangle
            {
                Width = 3,
                RadiusX = 1.5,
                RadiusY = 1.5,
                Fill = FindResource("AccentBrush") as Brush,
                Margin = new Thickness(5, 6, 0, 6),
            };
            grid.Children.Add(bar);
        }

        var content = new DockPanel { Margin = new Thickness(10, 6, 10, 6) };
        content.Children.Add(_testing ? BuildTestingIndicator() : BuildDelayBadge(route));
        content.Children.Add(new TextBlock
        {
            Text = route.Name,
            FontSize = 12,
            Foreground = FindResource("TextPrimary") as Brush,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(10, 0, 10, 0),
        });
        Grid.SetColumn(content, 1);
        grid.Children.Add(content);

        row.Child = grid;
        row.MouseLeftButtonUp += OnRouteClick;
        return row;
    }

    /// <summary>延迟徽章：圆角小胶囊，衬底 Badge*Brush + 分档前景色（<200 绿 / <500 黄 / 其余红）。</summary>
    private UIElement BuildDelayBadge(ClashRoute route)
    {
        var text = route.Delay is { } delay && delay > 0
            ? $"{delay}ms"
            : route.Delay == 0 ? Lang.Get(AppStrings.TimeoutBadge) : Lang.Get(AppStrings.UntestedBadge);
        var (backgroundKey, foregroundKey) = route.Delay switch
        {
            null => ("BadgeMutedBrush", "TextSecondary"),
            <= 0 => ("BadgeRedBrush", "AccentRed"), // 0 = 超时（负值不出现，防御同档）
            < 200 => ("BadgeGreenBrush", "AccentGreen"),
            < 500 => ("BadgeYellowBrush", "AccentYellow"),
            _ => ("BadgeRedBrush", "AccentRed"),
        };
        return new Border
        {
            Background = FindResource(backgroundKey) as Brush,
            CornerRadius = new CornerRadius(9),
            Padding = new Thickness(8, 2, 8, 2),
            VerticalAlignment = VerticalAlignment.Center,
            Child = new TextBlock
            {
                Text = text,
                FontSize = 11,
                FontWeight = FontWeights.SemiBold,
                Foreground = FindResource(foregroundKey) as Brush,
            },
        };
    }

    /// <summary>测速中行内动画：细条 IsIndeterminate（强调色滑动指示，无轨道底）。</summary>
    private UIElement BuildTestingIndicator() => new ProgressBar
    {
        IsIndeterminate = true,
        Width = 44,
        Height = 3,
        Foreground = FindResource("AccentBrush") as Brush,
        Background = Brushes.Transparent,
        BorderThickness = new Thickness(0),
        VerticalAlignment = VerticalAlignment.Center,
        Margin = new Thickness(2, 0, 2, 0),
    };

    private async void OnRouteClick(object sender, MouseButtonEventArgs e)
    {
        if (sender is not Border { Tag: string route } || _groupName is null)
        {
            return;
        }

        var ok = await AppHost.Clash.SwitchRouteAsync(route);
        if (ok)
        {
            _selectedRoute = route;
            GroupText.Text = GroupHeaderText();
            RebuildRoutes(route);
        }
        else
        {
            ErrorText.Text = Lang.Format(AppStrings.SwitchFailedFormat, DescribeClashFailure());
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
        GroupText.Text = Lang.Get(AppStrings.Testing);
        // 测速期间全组线路行以 indeterminate 细条代替延迟徽章（组级并发测速，逐行回填无进度语义）。
        _testing = true;
        RebuildRoutes(_routes.FirstOrDefault(static r => r.IsSelected)?.Name);
        try
        {
            var delays = await AppHost.Clash.TestGroupAsync(_groupName);
            if (delays is not null)
            {
                _routes = _routes
                    .Select(r => delays.TryGetValue(r.Name, out var delay) ? r with { Delay = delay } : r)
                    .ToList();
            }
            else
            {
                ErrorText.Text = Lang.Format(AppStrings.TestFailedFormat, DescribeClashFailure());
                ErrorText.Visibility = Visibility.Visible;
            }

            GroupText.Text = _groupName;
        }
        finally
        {
            _testing = false;
            TestButton.IsEnabled = true;
            RebuildRoutes(_routes.FirstOrDefault(static r => r.IsSelected)?.Name);
        }
    }

    private void OnReload(object sender, RoutedEventArgs e) => _ = ReloadAsync();
}
