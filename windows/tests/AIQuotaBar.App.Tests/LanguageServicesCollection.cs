// Swift 来源：无（Windows 端新增；测试并行隔离）。
// LanguageService 是进程级单例（当前语言全局可变状态），三类语言相关测试
// （字符串表/语言服务/错误映射）必须串行执行，避免并行改写当前语言导致偶发失败。

namespace AIQuotaBar.App.Tests;

[CollectionDefinition(Name)]
public sealed class LanguageServicesCollection
{
    public const string Name = "LanguageServices";
}
