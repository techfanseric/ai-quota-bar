// Swift 来源：AIQuotaBar/Models/AppLanguage.swift — enum AppLanguage + fallback（v1.28.1）
// Windows 形态（对齐 ThemeService 既定模式）：
//  - 三态偏好 LanguagePreference（跟随系统/中文/English）持久化于 AppSettings.Language
//    （旧 settings.json 缺字段 → null → FollowSystem，天然向后兼容；与 Theme 字段同构）；
//  - 生效语言 EffectiveLanguage：跟随模式下由 CultureInfo.CurrentUICulture 推导
//    （zh* → Chinese，其余 → English；对应 Swift Locale.preferredLanguages.first?.hasPrefix("zh")）；
//  - 即时切换：设置窗三选 Checked → ApplyPreference → LanguageChanged 事件 →
//    已开面板重建（QuotaPanel/RoutePanel 订阅，模式对齐 ThemeService.ThemeChanged）。
// 与 Providers.Clash.AppLanguage 的关系：那是 Clash 展示文本的临时子集（见其 TODO 去重注释），
// 本服务落地后 App 层文案统一走本类型 + AppStrings；Providers 不引用 App（分层铁律），
// 待后续编排统一时再收敛到 Core。

using System.Globalization;

namespace AIQuotaBar.App.Services;

/// <summary>用户语言偏好（持久化字符串与枚举名一致；未知/缺失值一律回落跟随系统）。</summary>
public enum LanguagePreference
{
    FollowSystem,
    Chinese,
    English,
}

/// <summary>实际生效语言（跟随模式下由系统 UI 文化推导）。</summary>
public enum EffectiveLanguage
{
    Chinese,
    English,
}

/// <summary>
/// 界面语言服务（全应用用户可见文案的唯一语言机制）。
/// 取值入口：静态 <see cref="Lang"/>（AppStrings/Lang.Get 的解析依据）。
/// 线程模型与 ThemeService 相同：Initialize/ApplyPreference 在 UI 线程调用；
/// Lang 读取无锁（枚举原子写），后台读到的旧值仅影响一次文案取值，无撕裂风险。
/// </summary>
public sealed class LanguageService
{
    /// <summary>语言切换即时通知（UI 线程回调；订阅方自行重建文案）。</summary>
    public event Action? LanguageChanged;

    public static LanguageService Instance { get; private set; } = new();

    public LanguagePreference Preference { get; private set; } = LanguagePreference.FollowSystem;

    public EffectiveLanguage Current { get; private set; } = EffectiveLanguage.English;

    /// <summary>当前生效语言（字符串表取值入口；测试经 ApplyPreference 变更）。</summary>
    public static EffectiveLanguage Lang => Instance.Current;

    private bool _appliedOnce;

    private LanguageService()
    {
    }

    /// <summary>App 启动时初始化（UI 线程）：应用持久化偏好。语言无注册表监听需求
    /// （Windows 无系统语言变更的轻量通知；跟随模式在每次 ApplyPreference 时重读文化）。</summary>
    public static void Initialize(LanguagePreference preference) => Instance.ApplyPreference(preference);

    /// <summary>设置窗三选即时生效入口；持久化由调用方（SettingsWindow.OnSave → AppSettings）负责。</summary>
    public void ApplyPreference(LanguagePreference preference)
    {
        Preference = preference;
        ApplyEffective();
    }

    /// <summary>settings.json 字符串 → 偏好（null/未知值回退跟随系统，向后兼容旧文件）。</summary>
    public static LanguagePreference ParsePreference(string? value) => value switch
    {
        nameof(LanguagePreference.Chinese) => LanguagePreference.Chinese,
        nameof(LanguagePreference.English) => LanguagePreference.English,
        _ => LanguagePreference.FollowSystem,
    };

    /// <summary>读系统 UI 语言（zh 开头 → Chinese，否则 English；对应 Swift fallback 判定）。</summary>
    public static EffectiveLanguage DetectSystemLanguage() =>
        DetectSystemLanguage(CultureInfo.CurrentUICulture);

    /// <summary>注入桩重载：测试传入任意 CultureInfo 验证推导规则（zh-CN/zh-Hans/zh-TW → Chinese）。</summary>
    public static EffectiveLanguage DetectSystemLanguage(CultureInfo uiCulture) =>
        string.Equals(uiCulture.TwoLetterISOLanguageName, "zh", StringComparison.OrdinalIgnoreCase)
            ? EffectiveLanguage.Chinese
            : EffectiveLanguage.English;

    private void ApplyEffective()
    {
        var effective = Preference switch
        {
            LanguagePreference.Chinese => EffectiveLanguage.Chinese,
            LanguagePreference.English => EffectiveLanguage.English,
            _ => DetectSystemLanguage(),
        };
        if (effective == Current && _appliedOnce)
        {
            return; // 幂等：重复应用（如三选重复点击）直接跳过，不触发重建。
        }

        _appliedOnce = true;
        Current = effective;
        LanguageChanged?.Invoke();
    }
}
