// Swift 来源：AIQuotaBar/Tests/AppLanguageTests.swift（对应 macOS 端语言文案测试的 Windows 形态）。
// 覆盖：字符串表键完整性（两语言所有键非空、表内只允许 AppText 条目）、
// Lang.Get 按当前语言取值、Lang.Format 双语占位符插值。

using System.Reflection;
using AIQuotaBar.App.Services;
using Xunit;

namespace AIQuotaBar.App.Tests;

[Collection(LanguageServicesCollection.Name)]
public sealed class AppStringsTests
{
    [Fact]
    public void AllEntries_AreNonEmptyAppTextInBothLanguages()
    {
        // 应然：字符串表所有公开静态字段都是 AppText 条目，且两语言文案皆非空；
        // 实然断言失败即说明有人往表里放了非条目成员或漏写了某种语言。
        var fields = typeof(AppStrings).GetFields(BindingFlags.Public | BindingFlags.Static);
        Assert.True(fields.Length >= 40, $"字符串表应有足量条目（当前 {fields.Length} 个），应然 ≥ 40");
        foreach (var field in fields)
        {
            Assert.Equal(typeof(AppText), field.FieldType); // 表内只允许条目字段，防止混入其他静态成员
            var entry = Assert.IsType<AppText>(field.GetValue(null));
            Assert.False(string.IsNullOrWhiteSpace(entry.Zh), $"{field.Name}.Zh 应非空");
            Assert.False(string.IsNullOrWhiteSpace(entry.En), $"{field.Name}.En 应非空");
        }
    }

    [Fact]
    public void Get_ResolvesEntryByCurrentLanguage()
    {
        LanguageService.Instance.ApplyPreference(LanguagePreference.Chinese);
        Assert.Equal("刷新", Lang.Get(AppStrings.Refresh));
        Assert.Equal("设置", Lang.Get(AppStrings.Settings));

        LanguageService.Instance.ApplyPreference(LanguagePreference.English);
        Assert.Equal("Refresh", Lang.Get(AppStrings.Refresh));
        Assert.Equal("Settings", Lang.Get(AppStrings.Settings));
    }

    [Fact]
    public void Format_InterpolatesPlaceholdersInBothLanguages()
    {
        LanguageService.Instance.ApplyPreference(LanguagePreference.Chinese);
        Assert.Equal("切换失败：boom", Lang.Format(AppStrings.SwitchFailedFormat, "boom"));
        Assert.Equal("整体 3/5", Lang.Format(AppStrings.OverallFormat, 3, 5));

        LanguageService.Instance.ApplyPreference(LanguagePreference.English);
        Assert.Equal("Switch failed: boom", Lang.Format(AppStrings.SwitchFailedFormat, "boom"));
        Assert.Equal("Overall 3/5", Lang.Format(AppStrings.OverallFormat, 3, 5));
    }

    [Fact]
    public void KnownKeys_KeepSwiftAlignedNaming()
    {
        // 应然：与 Swift AppText 重合的概念沿用同一键名（双端代码检索可对照）。
        var names = typeof(AppStrings).GetFields(BindingFlags.Public | BindingFlags.Static)
            .Select(static f => f.Name)
            .ToHashSet();
        foreach (var swiftKey in new[] { "Refresh", "Settings", "QuitApp", "Loading", "UnknownError", "LanguageTitle" })
        {
            Assert.Contains(swiftKey, names);
        }
    }
}
