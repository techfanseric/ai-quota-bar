// Swift 来源：AIQuotaBar/Models/AppLanguage.swift — func text(_ key: AppText) -> String（v1.28.1）
// Windows 取值入口：Lang.Get(entry) / Lang.Format(entry, args)，按 LanguageService.Lang 解析。

namespace AIQuotaBar.App.Services;

/// <summary>字符串表取值器（名字对齐 Swift AppLanguage.text 的调用形态 Lang.Get(...)）。</summary>
public static class Lang
{
    /// <summary>按当前生效语言取条目文案。</summary>
    public static string Get(AppText text) =>
        LanguageService.Lang == EffectiveLanguage.Chinese ? text.Zh : text.En;

    /// <summary>带参文案：先取当前语言格式串，再 string.Format 填参（占位符两语言一一对应）。</summary>
    public static string Format(AppText text, params object?[] args) =>
        string.Format(Get(text), args);
}
