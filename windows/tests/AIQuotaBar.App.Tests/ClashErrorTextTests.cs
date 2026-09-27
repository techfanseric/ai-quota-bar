// Swift 来源：无（Windows 端新增；Clash 错误 UI 映射表完整性与关键文案钉住）。
// 覆盖：ClashIntegrationError 每个子类型都有非空双语映射（反射遍历，新增错误类型漏配即失败）、
// ExternalControllerDisabled 的可操作文案逐字钉住（2026-09-25 真实案例的回归测试）、
// HttpRequestException 网络兜底与未知异常兜底。

using System.Net.Http;
using System.Reflection;
using AIQuotaBar.App.Services;
using AIQuotaBar.Providers.Clash;
using Xunit;

namespace AIQuotaBar.App.Tests;

[Collection(LanguageServicesCollection.Name)]
public sealed class ClashErrorTextTests
{
    [Fact]
    public void EveryClashIntegrationErrorVariant_MapsToNonEmptyTextInBothLanguages()
    {
        // 应然：ClashIntegrationError 的每个子类型在两种语言下都有非空可操作映射；
        // 实然：反射构造全部子类型实例逐一验证——新增错误类型漏配映射时在此失败。
        var errorTypes = typeof(ClashIntegrationError).GetNestedTypes(BindingFlags.Public);
        Assert.NotEmpty(errorTypes);
        foreach (var errorType in errorTypes)
        {
            var error = ConstructError(errorType);
            foreach (var preference in new[] { LanguagePreference.Chinese, LanguagePreference.English })
            {
                LanguageService.Instance.ApplyPreference(preference);
                var text = ClashErrorText.Describe(new ClashIntegrationException(error));
                Assert.False(
                    string.IsNullOrWhiteSpace(text),
                    $"{errorType.Name} 在 {preference} 下应有非空映射文案");
            }
        }
    }

    [Fact]
    public void ExternalControllerDisabled_UsesActionableBilingualText()
    {
        // 2026-09-25 真实案例回归：外部控制未开启必须给出「打开 Clash Verge 设置」的可操作指引，
        // 而不是裸英文技术消息 "Clash external controller is disabled."。
        LanguageService.Instance.ApplyPreference(LanguagePreference.Chinese);
        Assert.Equal(
            "Clash 已安装但外部控制未开启：打开 Clash Verge → 设置 → 开启「外部控制」。",
            ClashErrorText.Describe(new ClashIntegrationException(new ClashIntegrationError.ExternalControllerDisabled())));

        LanguageService.Instance.ApplyPreference(LanguagePreference.English);
        Assert.Equal(
            "Clash is installed but its external controller is off: enable it in Clash Verge settings.",
            ClashErrorText.Describe(new ClashIntegrationException(new ClashIntegrationError.ExternalControllerDisabled())));
    }

    [Fact]
    public void UnsafeControllerHost_ContainsHostInBothLanguages()
    {
        LanguageService.Instance.ApplyPreference(LanguagePreference.Chinese);
        Assert.Contains("0.0.0.0:9090", ClashErrorText.Describe(
            new ClashIntegrationException(new ClashIntegrationError.UnsafeControllerHost("0.0.0.0:9090"))));

        LanguageService.Instance.ApplyPreference(LanguagePreference.English);
        Assert.Contains("0.0.0.0:9090", ClashErrorText.Describe(
            new ClashIntegrationException(new ClashIntegrationError.UnsafeControllerHost("0.0.0.0:9090"))));
    }

    [Fact]
    public void HttpRequestException_MapsToGenericNetworkFailure()
    {
        LanguageService.Instance.ApplyPreference(LanguagePreference.Chinese);
        Assert.StartsWith("网络请求失败：", ClashErrorText.Describe(new HttpRequestException("refused")));

        LanguageService.Instance.ApplyPreference(LanguagePreference.English);
        Assert.StartsWith("Network request failed: ", ClashErrorText.Describe(new HttpRequestException("refused")));
    }

    [Fact]
    public void NullError_FallsBackToUnknownError()
    {
        LanguageService.Instance.ApplyPreference(LanguagePreference.Chinese);
        Assert.Equal("未知错误", ClashErrorText.Describe(null));

        LanguageService.Instance.ApplyPreference(LanguagePreference.English);
        Assert.Equal("Unknown error", ClashErrorText.Describe(null));
    }

    [Fact]
    public void OtherException_FallsBackToLocalizedPrefixWithTechnicalMessage()
    {
        LanguageService.Instance.ApplyPreference(LanguagePreference.Chinese);
        Assert.Equal("Clash 请求失败：boom", ClashErrorText.Describe(new InvalidOperationException("boom")));

        LanguageService.Instance.ApplyPreference(LanguagePreference.English);
        Assert.Equal("Clash request failed: boom", ClashErrorText.Describe(new InvalidOperationException("boom")));
    }

    /// <summary>反射构造错误子类型（当前构造参数仅 string/int，按参数类型给探测值）。</summary>
    private static ClashIntegrationError ConstructError(Type errorType)
    {
        var constructor = errorType.GetConstructors().Single();
        var arguments = constructor.GetParameters()
            .Select(p => p.ParameterType == typeof(int)
                ? (object)501
                : p.ParameterType == typeof(string)
                    ? "probe:9090"
                    : throw new NotSupportedException($"错误子类型 {errorType.Name} 含未覆盖的构造参数类型 {p.ParameterType.Name}，请同步更新探测值构造"))
            .ToArray();
        return (ClashIntegrationError)constructor.Invoke(arguments)!;
    }
}
