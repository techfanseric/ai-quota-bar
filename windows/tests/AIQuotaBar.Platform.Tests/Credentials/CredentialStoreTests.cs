// Swift 来源：无（Windows 端新增；对应计划 §4 平台映射：Keychain（SecItem）→ Credential Manager）
// 被测类型：AIQuotaBar.Platform/Credentials/CredentialStore.cs
// 真实 Credential Manager round-trip：service 名含 GUID 隔离，IDisposable 里统一清理（约定 §7.2）。

using System;
using AIQuotaBar.Platform.Credentials;
using Xunit;

namespace AIQuotaBar.Platform.Tests.Credentials;

[Trait("Category", "RequiresWindows")]
public sealed class CredentialStoreTests : IDisposable
{
    private readonly CredentialStore _store = new();
    private readonly string _service = $"quota-svc-test-{Guid.NewGuid():N}";
    private const string Account = "eric@example.com";

    public void Dispose()
    {
        // tearDown：无论断言结果如何都清掉写入的凭据（幂等删除）。
        _store.Delete(_service, Account);
        _store.Delete(_service, string.Empty);
    }

    [Fact]
    public void WriteThenRead_ReturnsSecret()
    {
        _store.Write(_service, Account, "sk-secret-12345");

        var read = _store.Read(_service, Account);

        // 应然：读回写入的密钥（实然：null 或变体字符串即失败）。
        Assert.Equal("sk-secret-12345", read!);
    }

    [Fact]
    public void Read_MissingCredential_ReturnsNull()
    {
        var read = _store.Read(_service, Account);

        Assert.Null(read);
    }

    [Fact]
    public void Write_OverwritesExistingValue()
    {
        _store.Write(_service, Account, "sk-old");
        _store.Write(_service, Account, "sk-new");

        var read = _store.Read(_service, Account);

        Assert.Equal("sk-new", read!);
    }

    [Fact]
    public void Delete_ExistingCredential_ReturnsTrueAndRemoves()
    {
        _store.Write(_service, Account, "sk-to-delete");

        var deleted = _store.Delete(_service, Account);

        Assert.True(deleted, "已存在的凭据删除应返回 true。");
        Assert.Null(_store.Read(_service, Account));
    }

    [Fact]
    public void Delete_MissingCredential_ReturnsFalse()
    {
        var deleted = _store.Delete(_service, Account);

        Assert.False(deleted, "不存在的凭据删除应返回 false（非异常）。");
    }

    [Fact]
    public void Write_EmptyAccount_UsesSeparateTarget()
    {
        // 账户可空（glm 等 provider 无账户维度）：不与带账户的同服务名冲突。
        _store.Write(_service, string.Empty, "sk-no-account");

        Assert.Equal("sk-no-account", _store.Read(_service, string.Empty)!);
        Assert.Null(_store.Read(_service, Account));
    }

    [Fact]
    public void Write_Utf8Secret_RoundTrips()
    {
        const string secret = "密钥-sk-🔐-值";
        _store.Write(_service, Account, secret);

        // 应然：UTF-8 blob 无损往返（实然：乱码即编码路径错误）。
        Assert.Equal(secret, _store.Read(_service, Account)!);
    }

    [Fact]
    public void Write_InvalidSegments_Throws()
    {
        Assert.Throws<ArgumentException>(() => _store.Write(string.Empty, Account, "sk"));
        Assert.Throws<ArgumentException>(() => _store.Write("bad:service", Account, "sk"));
        Assert.Throws<ArgumentException>(() => _store.Write(_service, "bad:account", "sk"));
    }
}
