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
        // 语言切换时刷新静态文案与可见内容（模式对齐主题切换；单例常驻，无需退订）。
        LanguageService.Instance.LanguageChanged += () =>
        {
            ApplyStrings();
            if (IsVisible)
            {
                Rebuild();
            }
        };
        ApplyStrings();
    }

    /// <summary>XAML 静态文案（标题/按钮）按当前语言填充；Rebuild 覆盖动态部分。</summary>
    private void ApplyStrings()
    {
        Title = Lang.Get(AppStrings.QuotaPanelTitle);
        RefreshButton.Content = Lang.Get(AppStrings.Refresh);
        SettingsButton.Content = Lang.Get(AppStrings.Settings);
        ExitButton.Content = Lang.Get(AppStrings.QuitApp);
    }

    private App AppHost => (App)Application.Current;

    private void Rebuild()
    {
        ProvidersHost.Children.Clear();
        RenderProvider(AppHost.Quota.Glm);
        RenderProvider(AppHost.Quota.Minimax);
        RenderProvider(AppHost.Quota.Codex);
        // 视觉装饰层（并行边界约定）：provider 节包卡片 + 头部环形图，不动 RenderProvider 逻辑。
        ProviderSectionChrome.DecorateAll(
            ProvidersHost, new[] { AppHost.Quota.Glm, AppHost.Quota.Minimax, AppHost.Quota.Codex });
        UpdatedText.Text = Lang.Format(AppStrings.UpdatedAtFormat, $"{DateTime.Now:HH:mm:ss}");
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
                statusText.Text = Lang.Format(AppStrings.PercentLeftFormat, usage.PercentageRemaining());
                statusText.Foreground = PercentBrush(usage.PercentageRemaining());
                foreach (var model in usage.Models)
                {
                    section.Children.Add(BuildModelRow(model));
                }

                if (usage.Models.Count == 0)
                {
                    section.Children.Add(new TextBlock
                    {
                        Text = Lang.Format(AppStrings.OverallFormat, usage.Remains, usage.Total),
                        Foreground = FindResource("TextSecondary") as Brush,
                        FontSize = 12,
                        Margin = new Thickness(0, 4, 0, 0),
                    });
                }

                break;

            case ProviderStatus.NotConfigured:
                statusText.Text = Lang.Get(AppStrings.NotConfigured);
                var configure = new Button
                {
                    Style = FindResource("PanelButton") as Style,
                    Content = Lang.Get(AppStrings.GoConfigureCredentials),
                    HorizontalAlignment = HorizontalAlignment.Left,
                    Margin = new Thickness(0, 4, 0, 0),
                };
                configure.Click += (_, _) => SettingsWindow.OpenOwned(this);
                section.Children.Add(configure);
                break;

            case ProviderStatus.Loading:
                statusText.Text = Lang.Get(AppStrings.Loading);
                break;

            case ProviderStatus.Error:
                statusText.Text = Lang.Get(AppStrings.Failed);
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
            value += Lang.Format(AppStrings.ModelPercentFormat, pct);
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
        // 图表化接入点（并行边界约定：仅此一行改调用）：文本行 + 模型行进度条（UsageBar）。
        return UsageBar.WrapModelRow(row, model);
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
        UpdatedText.Text = Lang.Get(AppStrings.Refreshing);
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
