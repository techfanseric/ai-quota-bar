// Swift 来源：无（Windows 端新增；对应计划 §4 平台映射：CryptoKit 部分场景 → DPAPI）
// 被测类型：AIQuotaBar.Platform/Crypto/DpapiProtector.cs
// 注意：DPAPI 绑定「当前用户 + 本机」，round-trip 在同一进程内完成即满足验证条件。

using System;
using System.Security.Cryptography;
using AIQuotaBar.Platform.Crypto;
using Xunit;

namespace AIQuotaBar.Platform.Tests.Crypto;

[Trait("Category", "RequiresWindows")]
public sealed class DpapiProtectorTests
{
    private readonly DpapiProtector _protector = new();

    [Fact]
    public void ProtectUnprotect_ByteArray_RoundTrips()
    {
        var plaintext = new byte[] { 0x00, 0x01, 0x02, 0xFE, 0xFF, 0x7F, 0x80, 0xC3 };

        var protectedBytes = _protector.Protect(plaintext);
        var restored = _protector.Unprotect(protectedBytes);

        // 应然：解保护后与原明文逐字节一致（实然：任何差异即 DPAPI 封装损坏）。
        Assert.Equal(plaintext, restored);
    }

    [Fact]
    public void ProtectUnprotect_Utf8String_RoundTrips()
    {
        // 含中文与 emoji：钉住 UTF-8 编码路径不被 Default 代码页替换。
        const string plaintext = "密钥 sk-测试-🔐-AIQuotaBar";

        var protectedText = _protector.Protect(plaintext);
        var restored = _protector.Unprotect(protectedText);

        Assert.Equal(plaintext, restored);
    }

    [Fact]
    public void ProtectString_ReturnsBase64_DistinctFromPlaintext()
    {
        const string plaintext = "sk-plain-secret-value";

        var first = _protector.Protect(plaintext);
        var second = _protector.Protect(plaintext);

        // 应然：输出为合法 Base64（可无异常解码且非空）……
        Assert.True(Convert.FromBase64String(first).Length > 0, "输出应是合法 Base64 密文。");
        // ……不含明文，且两次加密因随机盐而互不相同。
        Assert.DoesNotContain(plaintext, first, StringComparison.Ordinal);
        Assert.NotEqual(first, second);
    }

    [Fact]
    public void Unprotect_TamperedBlob_ThrowsCryptographicException()
    {
        var protectedBytes = _protector.Protect(new byte[] { 1, 2, 3, 4, 5, 6, 7, 8 });
        protectedBytes[^1] ^= 0xFF; // 翻转末字节：DPAPI blob 内含 MAC，篡改必须解密失败

        // 应然：抛 CryptographicException（实然：静默解出垃圾数据为失败）。
        Assert.Throws<CryptographicException>(() => _protector.Unprotect(protectedBytes));
    }

    [Fact]
    public void Unprotect_NonDpapiBytes_ThrowsCryptographicException()
    {
        var garbage = new byte[] { 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };

        Assert.Throws<CryptographicException>(() => _protector.Unprotect(garbage));
    }

    [Fact]
    public void Protect_NullOrEmptyInput_Throws()
    {
        Assert.Throws<ArgumentNullException>(() => _protector.Protect((byte[])null!));
        Assert.Throws<ArgumentException>(() => _protector.Protect(Array.Empty<byte>()));
        Assert.Throws<ArgumentNullException>(() => _protector.Protect((string)null!));
    }
}
