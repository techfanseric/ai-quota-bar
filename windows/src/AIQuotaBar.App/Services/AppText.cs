// Swift 来源：AIQuotaBar/Models/AppLanguage.swift — enum AppText 键枚举（v1.28.1）
// Windows 形态：每键一条内联双语条目（对齐 Swift 内联双语哲学，不用 resx）——
// (Zh, En) 值元组承载两种语言文案，取值经 Lang.Get/Lang.Format 按当前生效语言解析。

namespace AIQuotaBar.App.Services;

/// <summary>单条双语文案（键值一体：字段名即键，值即两种语言的文案）。</summary>
/// <param name="Zh">简体中文文案（可含 {0}/{1} 复合格式占位符）。</param>
/// <param name="En">English 文案（占位符与 Zh 一一对应）。</param>
public readonly record struct AppText(string Zh, string En);
