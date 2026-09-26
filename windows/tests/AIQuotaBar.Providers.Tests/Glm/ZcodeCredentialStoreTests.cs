// 来源：无 Swift 对应（Windows 端新增——ZcodeCredentialStore 的测试）。
// 样本全部合成（无任何真实凭据）：测试内用与被测实现同一方案（AES-256-GCM、key=SHA-256(secret)、
// iv 12 字节、tag 16 字节、无 AAD、base64url 三段 enc:v1）的 Encrypt 辅助现做密文；
// 另含一组由 Node 内置 crypto（v24，与 ZCode 客户端同源）生成的已知答案向量（KAT）钉住字节级互操作。

#nullable enable

using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using AIQuotaBar.Providers.Glm;
using Xunit;

namespace AIQuotaBar.Providers.Tests.Glm;

public sealed class ZcodeCredentialStoreTests
{
    private const string TestSecret = "aqb-zcode-test-secret";
    private const string EncryptedValuePrefix = "enc:v1:";
    private const int NonceSizeBytes = 12;
    private const int TagSizeBytes = 16;

    // ------------------------------------------------------------------
    // 往返：全键加密 → TryLoad 解回。
    // ------------------------------------------------------------------

    [Fact]
    public void RoundTripsEncryptedJwtAccessTokenAndApiKeys()
    {
        using var file = TempCredentialsFile.WithJson(CredentialsJson(
            ("zcodejwttoken", Encrypt(TestSecret, "eyJhbGciOiJFUzI1NiJ9.synthetic-jwt")),
            ("oauth:bigmodel:access_token", Encrypt(TestSecret, "synthetic-access-token")),
            ("account-provider:coding-plan:plan-a:api-key", Encrypt(TestSecret, "synthetic-api-key-a")),
            ("account-provider:coding-plan:plan-b:api-key", Encrypt(TestSecret, "synthetic-api-key-b")),
            // 非凭据键与 coding-plan 下非 api-key 后缀的键：均不得进入 ApiKeys。
            ("unrelated-setting", Encrypt(TestSecret, "ignored")),
            ("account-provider:coding-plan:plan-a:refresh-token", Encrypt(TestSecret, "ignored"))));
        var store = new ZcodeCredentialStore(file.CredentialsPath, TestSecret);

        var credentials = store.TryLoad();

        Assert.NotNull(credentials);
        // 应然：三个已知键全部解密回原文；ApiKeys 键为文件中的完整原键。
        Assert.Equal("eyJhbGciOiJFUzI1NiJ9.synthetic-jwt", credentials!.JwtToken);
        Assert.Equal("synthetic-access-token", credentials.AccessToken);
        Assert.Equal(2, credentials.ApiKeys.Count);
        Assert.Equal("synthetic-api-key-a", credentials.ApiKeys["account-provider:coding-plan:plan-a:api-key"]);
        Assert.Equal("synthetic-api-key-b", credentials.ApiKeys["account-provider:coding-plan:plan-b:api-key"]);
        Assert.DoesNotContain("unrelated-setting", credentials.ApiKeys.Keys);
        Assert.DoesNotContain("account-provider:coding-plan:plan-a:refresh-token", credentials.ApiKeys.Keys);
        Assert.Empty(credentials.Errors);
    }

    [Fact]
    public void PassesUnencryptedValuesThroughVerbatim()
    {
        using var file = TempCredentialsFile.WithJson(CredentialsJson(
            ("zcodejwttoken", "plain-jwt"),
            ("oauth:bigmodel:access_token", "plain-access-token"),
            ("account-provider:coding-plan:plan-a:api-key", "plain-api-key")));
        var store = new ZcodeCredentialStore(file.CredentialsPath, TestSecret);

        var credentials = store.TryLoad();

        Assert.NotNull(credentials);
        // 应然：无 enc:v1: 前缀的值原样透传（对齐 ZCode 客户端 decrypt 行为），且不产生错误。
        Assert.Equal("plain-jwt", credentials!.JwtToken);
        Assert.Equal("plain-access-token", credentials.AccessToken);
        Assert.Equal("plain-api-key", credentials.ApiKeys["account-provider:coding-plan:plan-a:api-key"]);
        Assert.Empty(credentials.Errors);
    }

    // ------------------------------------------------------------------
    // 文件缺失 / 坏 JSON → null。
    // ------------------------------------------------------------------

    [Fact]
    public void MissingFileReturnsNull()
    {
        var store = new ZcodeCredentialStore(TempCredentialsFile.MissingPath(), TestSecret);

        // 应然：文件不存在返回 null，不抛异常（Try 语义）。
        Assert.Null(store.TryLoad());
    }

    [Theory]
    [InlineData("not json {")]
    [InlineData("[]")]      // 根不是对象
    [InlineData("42")]      // 根不是对象
    public void MalformedJsonReturnsNull(string contents)
    {
        using var file = TempCredentialsFile.WithJson(contents);
        var store = new ZcodeCredentialStore(file.CredentialsPath, TestSecret);

        // 应然：坏 JSON / 根非对象一律 null（实然：抛异常即失败）。
        Assert.Null(store.TryLoad());
    }

    // ------------------------------------------------------------------
    // 单值解密失败：只废该键，其余继续。
    // ------------------------------------------------------------------

    [Fact]
    public void CorruptedTagNullsOnlyThatKeyAndRecordsError()
    {
        using var file = TempCredentialsFile.WithJson(CredentialsJson(
            ("zcodejwttoken", Encrypt(TestSecret, "healthy-jwt")),
            ("oauth:bigmodel:access_token", CorruptTag(Encrypt(TestSecret, "broken-access-token"))),
            ("account-provider:coding-plan:plan-a:api-key", "plain-api-key")));
        var store = new ZcodeCredentialStore(file.CredentialsPath, TestSecret);

        var credentials = store.TryLoad();

        Assert.NotNull(credentials);
        // 应然：tag 损坏的键置 null 并记入 Errors（含键名）；其余加密/明文键不受影响。
        Assert.Equal("healthy-jwt", credentials!.JwtToken);
        Assert.Null(credentials.AccessToken);
        Assert.Equal("plain-api-key", credentials.ApiKeys["account-provider:coding-plan:plan-a:api-key"]);
        var error = Assert.Single(credentials.Errors);
        Assert.Contains("oauth:bigmodel:access_token", error, StringComparison.Ordinal);
    }

    [Fact]
    public void MalformedEncValueNullsKey()
    {
        using var file = TempCredentialsFile.WithJson(CredentialsJson(
            // 分段数错 / base64 非法 / iv 长度错：三种畸形各占一键。
            ("zcodejwttoken", "enc:v1:only-one-segment"),
            ("oauth:bigmodel:access_token", "enc:v1:@@@.@@@.@@@"),
            ("account-provider:coding-plan:plan-a:api-key", WithIvSize(Encrypt(TestSecret, "x"), 6))));
        var store = new ZcodeCredentialStore(file.CredentialsPath, TestSecret);

        var credentials = store.TryLoad();

        Assert.NotNull(credentials);
        // 应然：三种畸形值各自置 null 并记入 Errors，不抛异常、不互相影响。
        Assert.Null(credentials!.JwtToken);
        Assert.Null(credentials.AccessToken);
        Assert.Empty(credentials.ApiKeys);
        Assert.Equal(3, credentials.Errors.Count);
    }

    [Fact]
    public void NonStringValueIsSkippedWithoutError()
    {
        using var file = TempCredentialsFile.WithJson("""{"zcodejwttoken":123,"oauth:bigmodel:access_token":"plain"}""");
        var store = new ZcodeCredentialStore(file.CredentialsPath, TestSecret);

        var credentials = store.TryLoad();

        Assert.NotNull(credentials);
        // 应然：非字符串值按“键缺失”处理（ZCode 端按字符串读取），不产生解密错误。
        Assert.Null(credentials!.JwtToken);
        Assert.Equal("plain", credentials.AccessToken);
        Assert.Empty(credentials.Errors);
    }

    // ------------------------------------------------------------------
    // secret 隔离：override 独立生效，secret 不匹配 → 干净失败。
    // ------------------------------------------------------------------

    [Fact]
    public void SecretOverrideUsesItsOwnSecret()
    {
        using var file = TempCredentialsFile.WithJson(CredentialsJson(
            ("zcodejwttoken", Encrypt("secret-a", "sealed-with-a"))));
        var withWrongSecret = new ZcodeCredentialStore(file.CredentialsPath, "secret-b");
        var withOwnSecret = new ZcodeCredentialStore(file.CredentialsPath, "secret-a");

        var mismatched = withWrongSecret.TryLoad();
        var matched = withOwnSecret.TryLoad();

        Assert.NotNull(mismatched);
        // 应然：secret 不匹配 → GCM tag 校验必然失败，该键 null + Errors 记录（不是明文乱码）。
        Assert.Null(mismatched!.JwtToken);
        Assert.Single(mismatched.Errors);

        Assert.NotNull(matched);
        // 应然：同一密文用加密时的 secret 可解回（secretOverride 独立于生产环境变量路径）。
        Assert.Equal("sealed-with-a", matched!.JwtToken);
    }

    // ------------------------------------------------------------------
    // Node crypto 已知答案向量（KAT）：钉住与 ZCode 客户端运行时的字节级互操作。
    // ------------------------------------------------------------------

    /// <summary>向量由 Node crypto（v24）按 ZCode 方案生成：iv=00..0b、secret=KnownAnswerSecret。</summary>
    private const string KnownAnswerSecret = "aqb-zcode-known-answer-secret";
    private const string KnownAnswerJwt =
        "enc:v1:AAECAwQFBgcICQoL.4j1ME9pRtmcX6gVUmsyk4w.evnHNbMmdYXdyFKR3CnQhB6Hfgb17sgIO3v7gTMKdmSRuxVkYXNjNUhrkBH5wI_dYLkMQ4IurLWn_SM44EL2";
    private const string KnownAnswerAccessToken =
        "enc:v1:AAECAwQFBgcICQoL.dqE-aLdF-t1ajYJvbXJPTQ.bPnjKbkEYoXxjHm06jbqxn2aW1S-85wAPXzz2DQGP2vLrEptcH5g";
    private const string KnownAnswerApiKey =
        "enc:v1:AAECAwQFBgcICQoL.SxJogM1GIwsKecE4k4zaFg.bPnjKbkEYoXxjHmn4H7y0CnDBA7proVTeSSmzDsLOGqDqQ";

    [Fact]
    public void NodeCryptoKnownAnswerVectorDecrypts()
    {
        using var file = TempCredentialsFile.WithJson(CredentialsJson(
            ("zcodejwttoken", KnownAnswerJwt),
            ("oauth:bigmodel:access_token", KnownAnswerAccessToken),
            ("account-provider:coding-plan:plan-a:api-key", KnownAnswerApiKey)));
        var store = new ZcodeCredentialStore(file.CredentialsPath, KnownAnswerSecret);

        var credentials = store.TryLoad();

        Assert.NotNull(credentials);
        // 应然：Node aes-256-gcm/base64url 产出的 enc:v1 值被逐字节解回（分段序、无 AAD、
        // SHA-256 摘要直作 key、无填充 base64url 字母表全在此钉住）。
        Assert.Equal("eyJhbGciOiJFUzI1NiJ9.synthetic-jwt-payload-for-aiquotabar-tests", credentials!.JwtToken);
        Assert.Equal("synthetic-access-token-from-node-crypto", credentials.AccessToken);
        Assert.Equal(
            "synthetic-api-key-0123456789abcdef",
            credentials.ApiKeys["account-provider:coding-plan:plan-a:api-key"]);
        Assert.Empty(credentials.Errors);
    }

    // ------------------------------------------------------------------
    // 平台串映射三态（win32/darwin/linux）。
    // ------------------------------------------------------------------

    [Theory]
    [InlineData(true, false, false, "win32")]
    [InlineData(false, true, false, "darwin")]
    [InlineData(false, false, true, "linux")]
    [InlineData(false, false, false, "unknown")]
    public void NodePlatformStringMapsThreeStates(bool isWindows, bool isMacOs, bool isLinux, string expected)
    {
        // 应然：RuntimeInformation 三态映射到 Node process.platform 串
        //（实然：任一映射错位即失败；三态需注入是因为 RuntimeInformation 只反映当前 OS）。
        Assert.Equal(expected, ZcodeCredentialStore.NodePlatformString(isWindows, isMacOs, isLinux));
    }

    // ------------------------------------------------------------------
    // 测试辅助：同方案加密 / 破坏 / 临时文件。
    // ------------------------------------------------------------------

    /// <summary>按 ZCode 方案加密一个 enc:v1 值（随机 iv）——测试侧独立实现，不借用生产代码。</summary>
    private static string Encrypt(string secret, string plaintext)
    {
        var key = SHA256.HashData(Encoding.UTF8.GetBytes(secret));
        var nonce = RandomNumberGenerator.GetBytes(NonceSizeBytes);
        var plainBytes = Encoding.UTF8.GetBytes(plaintext);
        var ciphertext = new byte[plainBytes.Length];
        var tag = new byte[TagSizeBytes];
        using var cipher = new AesGcm(key, TagSizeBytes);
        cipher.Encrypt(nonce, plainBytes, ciphertext, tag);
        return EncryptedValuePrefix
            + string.Join(".", ToBase64Url(nonce), ToBase64Url(tag), ToBase64Url(ciphertext));
    }

    /// <summary>翻转 tag 首字节后重组（保持结构合法，仅认证失败）。</summary>
    private static string CorruptTag(string encryptedValue) =>
        ReplaceSegment(encryptedValue, 1, tag =>
        {
            tag[0] ^= 0x01;
            return tag;
        });

    /// <summary>把 iv 段替换为指定长度的固定字节（制造长度畸形）。</summary>
    private static string WithIvSize(string encryptedValue, int size)
    {
        return ReplaceSegment(encryptedValue, 0, _ => new byte[size]);
    }

    private static string ReplaceSegment(string encryptedValue, int index, Func<byte[], byte[]> transform)
    {
        var segments = encryptedValue[EncryptedValuePrefix.Length..].Split('.');
        segments[index] = ToBase64Url(transform(DecodeBase64Url(segments[index])));
        return EncryptedValuePrefix + string.Join(".", segments);
    }

    private static string ToBase64Url(byte[] bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private static byte[] DecodeBase64Url(string encoded)
    {
        var builder = new StringBuilder(encoded)
            .Replace('-', '+')
            .Replace('_', '/');
        builder.Append('=', (4 - builder.Length % 4) % 4);
        return Convert.FromBase64String(builder.ToString());
    }

    private static string CredentialsJson(params (string Key, string Value)[] entries)
    {
        var root = new JsonObject();
        foreach (var (key, value) in entries)
        {
            root[key] = value;
        }

        return root.ToJsonString();
    }

    /// <summary>
    /// 临时 credentials.json（Path.GetTempPath + UUID 文件名；IDisposable 清理，
    /// 对应 Swift setUp/tearDown；先例：CodexAuthStoreTests.TempCodexHome）。
    /// </summary>
    private sealed class TempCredentialsFile : IDisposable
    {
        public string CredentialsPath { get; }

        private TempCredentialsFile(string path)
        {
            CredentialsPath = path;
        }

        public static TempCredentialsFile WithJson(string json)
        {
            var path = Path.Combine(
                Path.GetTempPath(),
                "aiquotabar-zcode-cred-tests-" + Guid.NewGuid().ToString("N") + ".json");
            File.WriteAllText(path, json);
            return new TempCredentialsFile(path);
        }

        /// <summary>指向不存在的文件（父目录也不存在），供“文件缺失”用例。</summary>
        public static string MissingPath() =>
            Path.Combine(
                Path.GetTempPath(),
                "aiquotabar-zcode-cred-tests-" + Guid.NewGuid().ToString("N"),
                "credentials.json");

        public void Dispose()
        {
            try
            {
                File.Delete(CredentialsPath);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // 清理失败不影响测试结果。
            }
        }
    }
}
