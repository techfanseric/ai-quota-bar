// Swift 来源：AIQuotaBar/Services/Clash/ClashConnectionModels.swift — enum ClashConnectionAgeScale（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashConnectionTests.swift — testAgeScaleClampsAtOneHour

#nullable enable

namespace AIQuotaBar.Providers.Clash;

/// <summary>连接年龄 → 颜色深浅进度：1 小时饱和，输入钳制在 [0, 1]。</summary>
public static class ClashConnectionAgeScale
{
    public const double OldestColorAgeSeconds = 60 * 60;

    public static double Progress(double age)
    {
        return Math.Min(Math.Max(age / OldestColorAgeSeconds, 0), 1);
    }
}
