// Swift 来源：AIQuotaBar/Services/Clash/ClashModels.swift — struct ClashRecoveryResult（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashRouteViewModelTests.swift（Swift 端无独立文件，判定值经
// windows/tests/AIQuotaBar.Providers.Tests/Clash/ClashRecoveryPolicyTests.cs 钉住）

#nullable enable

namespace AIQuotaBar.Providers.Clash;

/// <summary>一次成功自动恢复的结果：原线路、切换后的线路与其测速延迟。</summary>
public sealed record ClashRecoveryResult(
    string PreviousRoute,
    string SelectedRoute,
    int Delay)
{
    public bool DidSwitchRoute => PreviousRoute != SelectedRoute;
}
