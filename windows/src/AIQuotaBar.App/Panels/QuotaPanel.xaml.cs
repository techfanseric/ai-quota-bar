// Swift 来源：Views 控制中心（左键 NSPopover）—— Windows：PopupWindow 形态。
// 内容按 QuotaService 实时状态构建：每个 provider 一节（未配置/错误/配额行三态）。

using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
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
    }

    private App AppHost => (App)Application.Current;

    private void Rebuild()
    {
        ProvidersHost.Children.Clear();
        RenderProvider(AppHost.Quota.Glm);
        RenderProvider(AppHost.Quota.Minimax);
        UpdatedText.Text = $"更新于 {DateTime.Now:HH:mm:ss}";
        RefreshButton.IsEnabled = !_refreshing;
    }

    private void RenderProvider(ProviderState state)
    {
        var section = new StackPanel { Margin = new Thickness(12, 6, 12, 6) };

        var header = new DockPanel();
        header.Children.Add(new TextBlock
        {
            Text = state.Name,
            Foreground = FindResource("TextPrimary") as Brush,
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
        });
        var statusText = new TextBlock
        {
            HorizontalAlignment = HorizontalAlignment.Right,
            FontSize = 12,
            Foreground = FindResource("TextSecondary") as Brush,
        };
        header.Children.Add(statusText);
        section.Children.Add(header);

        switch (state.Status)
        {
            case ProviderStatus.Ok when state.Usage is { } usage:
                statusText.Text = $"{usage.PercentageRemaining():F1}% 剩余";
                statusText.Foreground = PercentBrush(usage.PercentageRemaining());
                foreach (var model in usage.Models)
                {
                    section.Children.Add(BuildModelRow(model));
                }

                if (usage.Models.Count == 0)
                {
                    section.Children.Add(new TextBlock
                    {
                        Text = $"整体 {usage.Remains}/{usage.Total}",
                        Foreground = FindResource("TextSecondary") as Brush,
                        FontSize = 12,
                        Margin = new Thickness(0, 4, 0, 0),
                    });
                }

                break;

            case ProviderStatus.NotConfigured:
                statusText.Text = "未配置";
                var configure = new Button
                {
                    Style = FindResource("PanelButton") as Style,
                    Content = "前往配置凭据 →",
                    HorizontalAlignment = HorizontalAlignment.Left,
                    Margin = new Thickness(0, 4, 0, 0),
                };
                configure.Click += (_, _) => SettingsWindow.OpenOwned(this);
                section.Children.Add(configure);
                break;

            case ProviderStatus.Loading:
                statusText.Text = "加载中…";
                break;

            case ProviderStatus.Error:
                statusText.Text = "失败";
                statusText.Foreground = FindResource("AccentRed") as Brush;
                section.Children.Add(new TextBlock
                {
                    Text = state.Error,
                    Foreground = FindResource("AccentRed") as Brush,
                    FontSize = 11,
                    TextWrapping = TextWrapping.Wrap,
                    Margin = new Thickness(0, 4, 0, 0),
                });
                break;
        }

        ProvidersHost.Children.Add(section);
    }

    private UIElement BuildModelRow(Core.Contracts.ModelUsageData model)
    {
        var row = new DockPanel { Margin = new Thickness(0, 5, 0, 0) };
        var account = string.IsNullOrEmpty(model.AccountName) ? null : $"{model.AccountName} · ";
        row.Children.Add(new TextBlock
        {
            Text = $"{account}{model.ModelName}",
            Foreground = FindResource("TextPrimary") as Brush,
            FontSize = 12,
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
            FontSize = 12,
            Foreground = model.CurrentIntervalRemainingPercent is { } p
                ? PercentBrush(p)
                : FindResource("TextSecondary") as Brush,
        };
        row.Children.Add(right);
        return row;
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

    private void OnExit(object sender, RoutedEventArgs e) => AppHost.ExitApplication();
}
