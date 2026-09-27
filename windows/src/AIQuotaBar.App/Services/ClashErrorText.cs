// Swift 来源：无（Windows 端新增；Providers 层异常 → UI 可操作文案的本地化映射层）。
// 设计（关键改进，源自 2026-09-25 真实案例：Clash 外部控制未开启，面板只显示
// 英文技术消息 "Clash external controller is disabled."，用户无从下手）：
//  - Providers 异常的英文消息**保持不动**（日志与诊断用途；分层铁律不越界改文案）；
//  - UI 层（RoutePanel）捕获后经本表按错误类型映射为可操作中文/英文提示，
//    文案取自 AppStrings（跟随应用内语言设置）；
//  - 映射完整性由 AIQuotaBar.App.Tests 反射钉住：ClashIntegrationError 的每个
//    子类型都必须有非空双语映射，新增错误类型漏配即测试失败。

using System.Net.Http;
using AIQuotaBar.Providers.Clash;

namespace AIQuotaBar.App.Services;

/// <summary>Clash 集成错误的 UI 文案映射（按 Error 类型分支，走 AppStrings 双语条目）。</summary>
public static class ClashErrorText
{
    /// <summary>
    /// 异常 → 可操作提示。ClashIntegrationException 按 Error 子类型映射；
    /// HttpRequestException（传输层）→ 通用网络失败；null → 未知错误兜底；
    /// 其余异常保留技术消息（ClashRequestFailedFormat 前缀 + 原消息）。
    /// </summary>
    public static string Describe(Exception? error) => error switch
    {
        ClashIntegrationException { Error: ClashIntegrationError.ExternalControllerDisabled }
            => Lang.Get(AppStrings.ClashErrorExternalControllerDisabled),
        ClashIntegrationException { Error: ClashIntegrationError.ConfigurationNotFound }
            => Lang.Get(AppStrings.ClashErrorConfigurationNotFound),
        ClashIntegrationException { Error: ClashIntegrationError.ControllerUnavailable }
            => Lang.Get(AppStrings.ClashErrorControllerUnavailable),
        ClashIntegrationException { Error: ClashIntegrationError.UnsafeControllerHost { Host: var host } }
            => Lang.Format(AppStrings.ClashErrorUnsafeControllerHostFormat, host),
        ClashIntegrationException { Error: ClashIntegrationError.InvalidControllerAddress { Address: var address } }
            => Lang.Format(AppStrings.ClashErrorInvalidControllerAddressFormat, address),
        ClashIntegrationException { Error: ClashIntegrationError.IncompatibleResponse }
            => Lang.Get(AppStrings.ClashErrorIncompatibleResponse),
        ClashIntegrationException { Error: ClashIntegrationError.StrategyGroupNotFound }
            => Lang.Get(AppStrings.ClashErrorStrategyGroupNotFound),
        ClashIntegrationException { Error: ClashIntegrationError.ApiFailure { StatusCode: var statusCode, Message: var message } }
            => Lang.Format(AppStrings.ClashErrorApiFailureFormat, statusCode, message),
        HttpRequestException http => Lang.Format(AppStrings.ErrorNetworkFormat, http.Message),
        null => Lang.Get(AppStrings.UnknownError),
        _ => Lang.Format(AppStrings.ClashRequestFailedFormat, error.Message),
    };
}
