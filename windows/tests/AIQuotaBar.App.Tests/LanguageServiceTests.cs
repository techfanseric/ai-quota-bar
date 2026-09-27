// Swift 来源：AIQuotaBar/Models/AppLanguage.swift — static var fallback/current 的等价验证
//（Windows 形态：三态偏好/持久化解析/系统语言检测注入桩/即时切换事件）。

using System.Globalization;
using AIQuotaBar.App.Services;
using Xunit;

namespace AIQuotaBar.App.Tests;

[Collection(LanguageServicesCollection.Name)]
public sealed class LanguageServiceTests
{
    [Theory]
    [InlineData(null, LanguagePreference.FollowSystem)]
    [InlineData("", LanguagePreference.FollowSystem)]
    [InlineData("bogus", LanguagePreference.FollowSystem)]
    [InlineData("FollowSystem", LanguagePreference.FollowSystem)]
    [InlineData("Chinese", LanguagePreference.Chinese)]
    [InlineData("English", LanguagePreference.English)]
    public void ParsePreference_MissingOrUnknownFallsBackToFollowSystem(
        string? raw, LanguagePreference expected)
    {
        // 应然：旧 settings.json 缺 Language 字段（null）或未知值 → 跟随系统，向后兼容。
        Assert.Equal(expected, LanguageService.ParsePreference(raw));
    }

    [Theory]
    [InlineData("zh-CN", EffectiveLanguage.Chinese)]
    [InlineData("zh-Hans", EffectiveLanguage.Chinese)]
    [InlineData("zh-TW", EffectiveLanguage.Chinese)]
    [InlineData("en-US", EffectiveLanguage.English)]
    [InlineData("fr-FR", EffectiveLanguage.English)]
    [InlineData("ja-JP", EffectiveLanguage.English)]
    public void DetectSystemLanguage_ZhPrefixChineseOtherwiseEnglish(
        string cultureName, EffectiveLanguage expected)
    {
        // 注入桩：任意 CultureInfo 直接验证推导规则（zh* → Chinese，其余 → English）。
        Assert.Equal(expected, LanguageService.DetectSystemLanguage(new CultureInfo(cultureName)));
    }

    [Fact]
    public void FollowSystem_ResolvesFromCurrentUICulture()
    {
        var original = CultureInfo.CurrentUICulture;
        try
        {
            CultureInfo.CurrentUICulture = new CultureInfo("zh-CN");
            LanguageService.Instance.ApplyPreference(LanguagePreference.FollowSystem);
            Assert.Equal(EffectiveLanguage.Chinese, LanguageService.Instance.Current);

            CultureInfo.CurrentUICulture = new CultureInfo("en-US");
            LanguageService.Instance.ApplyPreference(LanguagePreference.FollowSystem);
            Assert.Equal(EffectiveLanguage.English, LanguageService.Instance.Current);
        }
        finally
        {
            CultureInfo.CurrentUICulture = original;
        }
    }

    [Fact]
    public void ExplicitPreference_OverridesSystemCulture()
    {
        var original = CultureInfo.CurrentUICulture;
        try
        {
            CultureInfo.CurrentUICulture = new CultureInfo("zh-CN");
            LanguageService.Instance.ApplyPreference(LanguagePreference.English);
            Assert.Equal(EffectiveLanguage.English, LanguageService.Instance.Current);
            Assert.Equal(LanguagePreference.English, LanguageService.Instance.Preference);
        }
        finally
        {
            CultureInfo.CurrentUICulture = original;
        }
    }

    [Fact]
    public void LanguageChanged_FiresOnlyWhenEffectiveLanguageChanges()
    {
        LanguageService.Instance.ApplyPreference(LanguagePreference.Chinese);
        var fired = 0;
        void OnChanged() => fired++;
        LanguageService.Instance.LanguageChanged += OnChanged;
        try
        {
            LanguageService.Instance.ApplyPreference(LanguagePreference.English);
            Assert.Equal(1, fired); // 生效语言变化 → 通知重建

            LanguageService.Instance.ApplyPreference(LanguagePreference.English);
            Assert.Equal(1, fired); // 同值幂等：重复应用不再通知

            LanguageService.Instance.ApplyPreference(LanguagePreference.Chinese);
            Assert.Equal(2, fired);
        }
        finally
        {
            LanguageService.Instance.LanguageChanged -= OnChanged;
        }
    }

    [Fact]
    public void Lang_AccessorTracksCurrentLanguage()
    {
        LanguageService.Instance.ApplyPreference(LanguagePreference.Chinese);
        Assert.Equal(EffectiveLanguage.Chinese, LanguageService.Lang);

        LanguageService.Instance.ApplyPreference(LanguagePreference.English);
        Assert.Equal(EffectiveLanguage.English, LanguageService.Lang);
    }
}
