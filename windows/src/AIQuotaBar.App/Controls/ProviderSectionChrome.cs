// Swift 来源：无（Windows 端新增；provider 节的纯视觉装饰层）。
// 定位（并行边界约定）：QuotaPanel.RenderProvider/BuildModelRow 的渲染逻辑不动，
// provider 节的「分区卡片 + 头部环形图」由本类在 Rebuild 之后以 DOM 装饰完成——
// RenderProvider 产出的 section 形态（StackPanel，首子为头部 DockPanel）是本类的输入契约，
// 新增 provider（如 Codex）只要仍走 RenderProvider 即自动获得同样外观。
// 卡片视觉参数取主题字典：CardBrush / PanelBorder / CardCornerRadius / CardPadding / CardMargin。

using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using AIQuotaBar.App.Services;
using AIQuotaBar.Core.Quota;
using Brush = System.Windows.Media.Brush;

namespace AIQuotaBar.App.Controls;

/// <summary>provider 节装饰器：包卡片、头部插环形图、区块标题调 Secondary 色。</summary>
public static partial class ProviderSectionChrome
{
    /// <summary>RenderProvider 头部状态文本的现行格式（AppStrings.PercentLeftFormat：
    /// zh "82.0% 剩余" / en "82.0% left"，两语言同为数字前缀），未登记状态时的兜底解析源。</summary>
    [GeneratedRegex(@"^(\d+(?:\.\d+)?)% ")]
    private static partial Regex RemainingPercentPrefix();

    /// <summary>
    /// 装饰宿主内的全部 provider 节：逐个包成卡片并在有配额数据的节头部插入环形图。
    /// percent 来源两级：ProviderState.Name 匹配（主，states 由调用方传入）→ 头部状态文本解析（兜底，
    /// 覆盖调用方尚未登记的新 provider）。
    /// </summary>
    public static void DecorateAll(Panel host, IReadOnlyList<ProviderState> states)
    {
        var sections = host.Children.OfType<UIElement>().ToList();
        host.Children.Clear();
        var statesByName = states
            .Where(static state => state.Usage is not null)
            .GroupBy(static state => state.Name, StringComparer.Ordinal)
            .ToDictionary(static group => group.Key, static group => group.First(), StringComparer.Ordinal);
        foreach (var section in sections)
        {
            host.Children.Add(Decorate(section, statesByName));
        }
    }

    private static UIElement Decorate(UIElement section, IReadOnlyDictionary<string, ProviderState> statesByName)
    {
        var card = new Border
        {
            Background = ResolveBrush("CardBrush"),
            BorderBrush = ResolveBrush("PanelBorder"),
            BorderThickness = ResolveThickness("CardBorderThickness"),
            CornerRadius = ResolveCornerRadius("CardCornerRadius"),
            Padding = ResolveThickness("CardPadding"),
            Margin = ResolveThickness("CardMargin"),
            SnapsToDevicePixels = true,
        };

        if (section is StackPanel stack)
        {
            DecorateHeader(stack, statesByName);
        }

        card.Child = section;
        return card;
    }

    /// <summary>头部（首子 DockPanel）插入环形图 + 区块标题调 Secondary；无配额数据节保持原样。</summary>
    private static void DecorateHeader(StackPanel section, IReadOnlyDictionary<string, ProviderState> statesByName)
    {
        if (section.Children.OfType<DockPanel>().FirstOrDefault() is not { } header)
        {
            return;
        }

        var percent = ResolveHeaderPercent(header, statesByName);
        if (percent is null)
        {
            return;
        }

        var gauge = new QuotaGauge
        {
            Percent = percent,
            Width = ResolveMetric("GaugeSize", 60),
            Height = ResolveMetric("GaugeSize", 60),
            VerticalAlignment = VerticalAlignment.Center,
        };
        gauge.SetValue(DockPanel.DockProperty, Dock.Left);
        header.Children.Insert(0, gauge);

        // 环形图与文字区拉开 8px 节奏；标题层级：区块标题 13px SemiBold Secondary（规格 §2）。
        header.Margin = new Thickness(8, 0, 0, 0);
        header.VerticalAlignment = VerticalAlignment.Center;
        if (header.Children.OfType<TextBlock>().FirstOrDefault() is { } title)
        {
            title.VerticalAlignment = VerticalAlignment.Center;
            title.Foreground = ResolveBrush("TextSecondary");
        }
    }

    private static double? ResolveHeaderPercent(
        DockPanel header,
        IReadOnlyDictionary<string, ProviderState> statesByName)
    {
        var blocks = header.Children.OfType<TextBlock>().ToList();
        if (blocks.Count == 0)
        {
            return null;
        }

        // 主路径：头部首 TextBlock 文本 = ProviderState.Name。
        if (statesByName.TryGetValue(blocks[0].Text, out var state) && state.Usage is { } usage)
        {
            return usage.PercentageRemaining();
        }

        // 兜底路径：状态文本数字前缀解析（zh "82.0% 剩余" / en "82.0% left" 同构；
        // 防御调用方未登记的新 provider 节）。
        var match = RemainingPercentPrefix().Match(blocks[^1].Text);
        return match.Success && double.TryParse(match.Groups[1].ValueSpan, System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture, out var parsed)
            ? parsed
            : null;
    }

    private static Brush ResolveBrush(string key) =>
        Application.Current?.TryFindResource(key) as Brush
        ?? throw new InvalidOperationException($"主题字典缺少键 {key}（Light/Dark.xaml 键位清单应严格一致）");

    private static System.Windows.Thickness ResolveThickness(string key) =>
        Application.Current?.TryFindResource(key) is System.Windows.Thickness thickness
            ? thickness
            : throw new InvalidOperationException($"主题字典缺少键 {key}（Light/Dark.xaml 键位清单应严格一致）");

    private static System.Windows.CornerRadius ResolveCornerRadius(string key) =>
        Application.Current?.TryFindResource(key) is System.Windows.CornerRadius corner
            ? corner
            : throw new InvalidOperationException($"主题字典缺少键 {key}（Light/Dark.xaml 键位清单应严格一致）");

    private static double ResolveMetric(string key, double fallback) =>
        Application.Current?.TryFindResource(key) is double value && value > 0 ? value : fallback;
}
