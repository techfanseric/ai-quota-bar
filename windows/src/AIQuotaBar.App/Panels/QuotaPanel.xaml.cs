// Swift 来源：Views 控制中心（左键 NSPopover）—— Windows：PopupWindow 形态。
// 内容按 QuotaService 实时状态构建：每个 provider 一节（未配置/错误/配额行三态）。

using System.Windows;
using AIQuotaBar.Core.Quota;
using Brushes = System.Windows.Media.Brushes;
using Brush = System.Windows.Media.Brush;
using Application = System.Windows.Application;
using System.Windows.Controls;
using System.Windows.Media;
using AIQuotaBar.App.Controls;
using AIQuotaBar.App.Services;

namespace AIQuotaBar.App.Panels;

public partial class QuotaPanel : PopupWindow
{
    private bool _refreshing;

    public static QuotaPanel Instance { get; } = new();

    private QuotaPanel()
    {
        InitializeComponent();
        IsVisibleChanged += (_, e) =>
        {
            if ((bool)e.NewValue)
            {
                Rebuild();
            }
        };
        // 主题切换（含跟随系统的注册表即时回调）时重建内容：图表控件画刷在重建时重新解析。
        ThemeService.Instance.ThemeChanged += () =>
        {
            if (IsVisible)
            {
                Rebuild();
            }
        };
    }

    private App AppHost => (App)Application.Current;

    private void Rebuild()
    {
        ProvidersHost.Children.Clear();
        RenderProvider(AppHost.Quota.Glm);
        RenderProvider(AppHost.Quota.Minimax);
        RenderProvider(AppHost.Quota.Codex);
        UpdatedText.Text = DateTime.Now.ToString("HH:mm:ss");
        RefreshButton.IsEnabled = !_refreshing;
    }

    private void RenderProvider(ProviderState state)
    {
        var remaining = state.Status == ProviderStatus.Ok && state.Usage is { } okUsage
            ? okUsage.PercentageRemaining()
            : (double?)null;
        var section = new Grid { Margin = new Thickness(16, 12, 16, 12) };
        section.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(44) });
        section.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        section.Children.Add(new QuotaGauge
        {
            Percent = remaining,
            Width = 38,
            Height = 38,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 1, 0, 0),
        });

        var details = new StackPanel();
        Grid.SetColumn(details, 1);
        var header = new Grid();
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(new TextBlock
        {
            Text = state.Name,
            Foreground = FindResource("TextPrimary") as Brush,
            FontSize = 12.5,
            FontWeight = FontWeights.SemiBold,
        });
        var statusText = new TextBlock
        {
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
            FontSize = 11.5,
            Foreground = FindResource("TextSecondary") as Brush,
        };
        Grid.SetColumn(statusText, 1);
        header.Children.Add(statusText);
        details.Children.Add(header);

        switch (state.Status)
        {
            case ProviderStatus.Ok when state.Usage is { } usage:
                statusText.Text = $"剩余 {usage.PercentageRemaining():F0}%";
                statusText.Foreground = PercentBrush(usage.PercentageRemaining());
                foreach (var model in usage.Models)
                {
                    details.Children.Add(BuildModelRow(model));
                }

                if (usage.Models.Count == 0)
                {
                    details.Children.Add(new TextBlock
                    {
                        Text = $"整体 {usage.Remains}/{usage.Total}",
                        Foreground = FindResource("TextSecondary") as Brush,
                        FontSize = 11,
                        Margin = new Thickness(0, 5, 0, 0),
                    });
                }

                break;

            case ProviderStatus.NotConfigured:
                statusText.Text = "未配置";
                var configure = new Button
                {
                    Style = FindResource("InlineActionButton") as Style,
                    Content = "前往配置凭据 →",
                    HorizontalAlignment = HorizontalAlignment.Left,
                    Margin = new Thickness(0, 5, 0, 0),
                };
                configure.Click += (_, _) => SettingsWindow.OpenOwned(this);
                details.Children.Add(configure);
                break;

            case ProviderStatus.Loading:
                statusText.Text = "加载中…";
                break;

            case ProviderStatus.Error:
                statusText.Text = "失败";
                statusText.Foreground = FindResource("AccentRed") as Brush;
                details.Children.Add(new TextBlock
                {
                    Text = state.Error,
                    Foreground = FindResource("AccentRed") as Brush,
                    FontSize = 10.5,
                    TextWrapping = TextWrapping.Wrap,
                    MaxHeight = 34,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    Margin = new Thickness(0, 5, 0, 0),
                });
                break;
        }

        section.Children.Add(details);
        ProvidersHost.Children.Add(new Border
        {
            BorderBrush = FindResource("SeparatorBrush") as Brush,
            BorderThickness = new Thickness(0, 1, 0, 0),
            Child = section,
        });
    }

    private UIElement BuildModelRow(Core.Contracts.ModelUsageData model)
    {
        var block = new StackPanel { Margin = new Thickness(0, 7, 0, 0) };
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var account = string.IsNullOrEmpty(model.AccountName) ? null : $"{model.AccountName} · ";
        row.Children.Add(new TextBlock
        {
            Text = $"{account}{model.ModelName}",
            Foreground = FindResource("TextPrimary") as Brush,
            FontSize = 11,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });

        var value = $"{model.CurrentIntervalRemaining}/{model.CurrentIntervalTotal}{model.ValueSuffix ?? string.Empty}";
        if (model.CurrentIntervalRemainingPercent is { } pct)
        {
            value += $"（{pct}%）";
        }

        var right = new TextBlock
        {
            Text = value,
            HorizontalAlignment = HorizontalAlignment.Right,
            FontSize = 11,
            Foreground = model.CurrentIntervalRemainingPercent is { } p
                ? PercentBrush(p)
                : FindResource("TextSecondary") as Brush,
            Margin = new Thickness(8, 0, 0, 0),
        };
        Grid.SetColumn(right, 1);
        row.Children.Add(right);
        block.Children.Add(row);
        var bar = UsageBar.ForModel(model);
        bar.Height = 4;
        bar.Margin = new Thickness(0, 4, 0, 0);
        block.Children.Add(bar);
        return block;
    }

    private Brush PercentBrush(double percent) => percent switch
    {
        > 50 => FindResource("AccentGreen") as Brush ?? Brushes.Green,
        > 20 => FindResource("AccentYellow") as Brush ?? Brushes.Orange,
        _ => FindResource("AccentRed") as Brush ?? Brushes.Red,
    };

    private async void OnRefresh(object sender, RoutedEventArgs e)
    {
        if (_refreshing)
        {
            return;
        }

        _refreshing = true;
        RefreshButton.IsEnabled = false;
        UpdatedText.Text = "刷新中…";
        try
        {
            await AppHost.Quota.RefreshAsync();
            Rebuild();
        }
        finally
        {
            _refreshing = false;
        }
    }

    private void OnSettings(object sender, RoutedEventArgs e) => SettingsWindow.OpenOwned(this);

    private void OnRoutes(object sender, RoutedEventArgs e)
    {
        Hide();
        App.ShowPanel(RoutePanel.Instance);
    }
}
