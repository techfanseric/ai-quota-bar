// Swift 来源：AIQuotaBar/Services/Clash/ClashModels.swift — enum ClashIntegrationError: LocalizedError（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashConfigurationDiscoveryTests.swift、ClashConnectionTests.swift 等
//
// Swift 的关联值枚举在 C# 以封闭 record 层级表达（需继承，故非 sealed 根类型——
// 见 coding-conventions §5）。抛出时包在 ClashIntegrationException 里（Swift 直接 throws 枚举）。

#nullable enable

namespace AIQuotaBar.Providers.Clash;

/// <summary>Clash 集成层的结构化错误（Swift ClashIntegrationError 的 errorDescription 以 Description 镜像）。</summary>
public abstract record ClashIntegrationError
{
    protected ClashIntegrationError() { }

    public sealed record ConfigurationNotFound : ClashIntegrationError;

    public sealed record ExternalControllerDisabled : ClashIntegrationError;

    public sealed record UnsafeControllerHost(string Host) : ClashIntegrationError;

    public sealed record InvalidControllerAddress(string Address) : ClashIntegrationError;

    public sealed record ControllerUnavailable : ClashIntegrationError;

    public sealed record IncompatibleResponse : ClashIntegrationError;

    public sealed record StrategyGroupNotFound : ClashIntegrationError;

    public sealed record ApiFailure(int StatusCode, string Message) : ClashIntegrationError;

    /// <summary>Swift errorDescription 的英文镜像（供日志与异常消息使用；界面文案由 App 层本地化）。</summary>
    public string Description => this switch
    {
        ConfigurationNotFound => "Clash configuration was not found.",
        ExternalControllerDisabled => "Clash external controller is disabled.",
        UnsafeControllerHost { Host: var host } => $"Clash controller is not bound to a local address ({host}).",
        InvalidControllerAddress { Address: var address } => $"Invalid Clash controller address: {address}",
        ControllerUnavailable => "Clash controller is unavailable.",
        IncompatibleResponse => "Clash returned an incompatible response.",
        StrategyGroupNotFound => "No switchable OpenAI strategy group was found.",
        ApiFailure { StatusCode: var statusCode, Message: var message } => $"Clash API {statusCode}: {message}",
        _ => ToString(),
    };
}
