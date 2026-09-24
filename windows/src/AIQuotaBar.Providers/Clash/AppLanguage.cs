// Swift 来源：AIQuotaBar/Models/AppLanguage.swift — enum AppLanguage（Clash 展示文本所需子集，v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashRouteSwitchHistoryStoreTests.swift — testRecentSwitchesUseRelativeMinutesForFirstHour
// TODO(去重)：App 层落地共享语言枚举（Core/Contracts）后替换本类型，避免各 provider 各自复制。

#nullable enable

namespace AIQuotaBar.Providers.Clash;

/// <summary>界面语言（Swift AppLanguage 的 Clash 消费子集）。</summary>
public enum AppLanguage
{
    English,
    SimplifiedChinese,
}
