// Swift 来源：无（Windows 端新增）。数据源：ZCode CLI 客户端（3.14.3）自身的凭据文件
// ~/.zcode/v2/credentials.json——加密方案逆向自其 app.asar out/host/index.js 的
// createCredentialCipherProvider，并已在实机解密验证（macOS 端 AIQuotaBar 不读 ZCode 凭据，
// 故无 Swift 对应）。本文件是 GLM coding-plan 的数据源之一，零平台依赖（纯 BCL）。
// 对应测试：AIQuotaBar.Providers.Tests/Glm/ZcodeCredentialStoreTests.cs（含 Node crypto 已知答案向量）。
//
// 加密方案（与 ZCode 客户端逐字段对齐）：
// - 文件是 JSON 对象，每个值为字符串；加密值前缀 "enc:v1:"，其后为三段 base64url 以 '.' 分隔：
//   iv.tag.ciphertext（AES-256-GCM，iv 12 字节、tag 16 字节、无 AAD）。
// - key = SHA-256(secret) 的原始 32 字节摘要。secret = 环境变量 ZCODE_CREDENTIAL_SECRET
//   （设置时整值原样使用；空串视为未设置——对齐 Node 侧 truthiness 判定）；未设置则用回退串
//   "zcode-credential-fallback:{platform}:{homedir}:{username}"（platform 取 Node process.platform
//   三态 win32/darwin/linux，homedir 为主目录绝对路径，username 取不到时 Node 用 "unknown"）。
// - 关键设计事实：实测跨机器拷贝的 credentials.json 解不开，只因 platform/homedir/username 三段
//   拼进了回退串——并非 OS 级密钥绑定（无 DPAPI/Keychain 参与），同一台机器上的任意进程都能解。
// - 未加密（无 enc:v1: 前缀）的值按原样透传（对齐 ZCode 客户端 decrypt 的行为）。

#nullable enable

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AIQuotaBar.Providers.Glm;

/// <summary>
/// 读取 ZCode 客户端凭据文件并解密 GLM coding-plan 相关条目（JWT、OAuth access token、
/// 按账号的 API key）。路径与 secret 均可注入（先例：ClashConfigurationDiscovery 的路径注入
/// 风格），便于测试指向临时文件与独立密钥；单值解密失败不整体失败（见 <see cref="TryLoad"/>）。
/// </summary>
public sealed class ZcodeCredentialStore
{
    private const string EncryptedValuePrefix = "enc:v1:";
    private const string JwtTokenKey = "zcodejwttoken";
    private const string AccessTokenKey = "oauth:bigmodel:access_token";
    private const string ApiKeyEntryPrefix = "account-provider:coding-plan:";
    private const string ApiKeyEntrySuffix = ":api-key";
    private const string SecretEnvironmentVariable = "ZCODE_CREDENTIAL_SECRET";
    private const string FallbackSecretPrefix = "zcode-credential-fallback:";

    /// <summary>username 取不到时 Node 用 "unknown"；此处同值兼作三态映射外平台的防御值。</summary>
    private const string UnknownValue = "unknown";
    private const int NonceSizeBytes = 12;
    private const int TagSizeBytes = 16;

    private readonly string _credentialsPath;
    private readonly string? _secretOverride;

    /// <param name="credentialsPath">
    /// 凭据文件完整路径；null 时用 %USERPROFILE%\.zcode\v2\credentials.json（测试注入临时文件）。
    /// </param>
    /// <param name="secretOverride">
    /// 测试注入的 secret；null 时按生产语义解析（环境变量 ZCODE_CREDENTIAL_SECRET → 回退串）。
    /// </param>
    public ZcodeCredentialStore(string? credentialsPath = null, string? secretOverride = null)
    {
        _credentialsPath = credentialsPath ?? DefaultCredentialsPath();
        _secretOverride = secretOverride;
    }

    /// <summary>
    /// 读取并解密凭据文件。文件不存在、不可读或 JSON 解析失败（含根不是对象）→ null。
    /// 未加密的值原样透传；任何单个值解密失败（tag 校验失败、分段畸形、base64 非法）不整体失败：
    /// 该键置 null 并记入 <see cref="ZcodeCredentials.Errors"/>，其余键继续。
    /// </summary>
    public ZcodeCredentials? TryLoad()
    {
        string contents;
        try
        {
            // 一次性读而不是先探测存在性（TOCTOU 窗口，先例：CodexAuthStore.ReadAuthJsonAsync）；
            // FileNotFoundException / DirectoryNotFoundException 均派生自 IOException，一并视作“读不到”。
            contents = File.ReadAllText(_credentialsPath);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return null;
        }

        JsonObject root;
        try
        {
            if (JsonNode.Parse(contents) is not JsonObject parsed)
            {
                return null;
            }

            root = parsed;
        }
        catch (JsonException)
        {
            return null;
        }

        using var cipher = CreateCipher(ResolveSecret());
        var errors = new List<string>();

        var jwtToken = DecryptEntry(root, JwtTokenKey, cipher, errors);
        var accessToken = DecryptEntry(root, AccessTokenKey, cipher, errors);

        var apiKeys = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var entry in root.Where(entry => IsApiKeyEntry(entry.Key))
                     .OrderBy(entry => entry.Key, StringComparer.Ordinal))
        {
            var plainKey = DecryptEntry(root, entry.Key, cipher, errors);
            if (plainKey is not null)
            {
                apiKeys[entry.Key] = plainKey;
            }
        }

        return new ZcodeCredentials(jwtToken, accessToken, apiKeys, errors);
    }

    /// <summary>
    /// Node process.platform 字符串映射：Windows → "win32"、macOS → "darwin"、Linux → "linux"
    /// （ZCode 支持范围外平台给 "unknown"，仅作防御）。独立成纯函数是因 RuntimeInformation
    /// 只能反映当前 OS，三态映射需在测试里逐态钉住。
    /// </summary>
    public static string NodePlatformString(bool isWindows, bool isMacOs, bool isLinux) =>
        isWindows ? "win32" : isMacOs ? "darwin" : isLinux ? "linux" : UnknownValue;

    private static string CurrentNodePlatformString() =>
        NodePlatformString(
            RuntimeInformation.IsOSPlatform(OSPlatform.Windows),
            RuntimeInformation.IsOSPlatform(OSPlatform.OSX),
            RuntimeInformation.IsOSPlatform(OSPlatform.Linux));

    private static string DefaultCredentialsPath() =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".zcode",
            "v2",
            "credentials.json");

    /// <summary>secret 解析优先级：测试注入 → 环境变量（非空整值）→ 回退串。</summary>
    private string ResolveSecret()
    {
        if (_secretOverride is not null)
        {
            return _secretOverride;
        }

        var environmentSecret = Environment.GetEnvironmentVariable(SecretEnvironmentVariable);
        if (!string.IsNullOrEmpty(environmentSecret))
        {
            // 整值原样作为 secret，不 trim / 不归一（ZCode 侧同为整值使用）。
            return environmentSecret;
        }

        var username = Environment.UserName;
        return FallbackSecretPrefix + string.Join(
            ":",
            CurrentNodePlatformString(),
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            string.IsNullOrEmpty(username) ? UnknownValue : username);
    }

    /// <summary>key = SHA-256(secret) 的原始 32 字节摘要（Node createHash("sha256").digest() 同构）。</summary>
    private static AesGcm CreateCipher(string secret)
    {
        var key = SHA256.HashData(Encoding.UTF8.GetBytes(secret));

        // 显式 tagSizeInBytes 构造器：.NET 8 对不传 tag 大小的 AesGcm 构造器报 SYSLIB0053，
        // TreatWarningsAsErrors 下即编译失败；GCM tag 恒为 16 字节（与 ZCode 客户端一致）。
        return new AesGcm(key, TagSizeBytes);
    }

    private static bool IsApiKeyEntry(string key) =>
        key.StartsWith(ApiKeyEntryPrefix, StringComparison.Ordinal) &&
        key.EndsWith(ApiKeyEntrySuffix, StringComparison.Ordinal) &&
        key.Length > ApiKeyEntryPrefix.Length + ApiKeyEntrySuffix.Length;

    /// <summary>
    /// 读取单个条目：键缺失或非字符串值 → null（不视作错误）；未加密 → 原样透传；
    /// 加密 → 解密，失败则该键置 null 并记入 errors（含键名，不含任何密文/明文材料）。
    /// </summary>
    private static string? DecryptEntry(
        JsonObject root,
        string key,
        AesGcm cipher,
        List<string> errors)
    {
        if (root[key] is not JsonValue value || !value.TryGetValue<string>(out var stored))
        {
            return null;
        }

        if (!stored.StartsWith(EncryptedValuePrefix, StringComparison.Ordinal))
        {
            return stored;
        }

        try
        {
            return DecryptEncryptedValue(cipher, stored);
        }
        catch (Exception ex) when (ex is CryptographicException or FormatException)
        {
            // 单值失败（tag 校验失败 / 分段畸形 / base64 非法）不整体失败：记键名继续。
            errors.Add($"{key}: decrypt failed ({ex.GetType().Name})");
            return null;
        }
    }

    private static string DecryptEncryptedValue(AesGcm cipher, string stored)
    {
        var segments = stored[EncryptedValuePrefix.Length..].Split('.');
        if (segments.Length != 3)
        {
            throw new FormatException("Expected three base64url segments: iv.tag.ciphertext");
        }

        var nonce = DecodeBase64Url(segments[0]);
        var tag = DecodeBase64Url(segments[1]);
        var ciphertext = DecodeBase64Url(segments[2]);

        if (nonce.Length != NonceSizeBytes || tag.Length != TagSizeBytes)
        {
            throw new FormatException($"Expected {NonceSizeBytes}-byte iv and {TagSizeBytes}-byte tag");
        }

        var plaintext = new byte[ciphertext.Length];
        cipher.Decrypt(nonce, ciphertext, tag, plaintext);
        return Encoding.UTF8.GetString(plaintext);
    }

    /// <summary>base64url 解码（无填充、'-'/'_' 字母表；先例：CodexAuthStore.DecodeBase64Url）。</summary>
    private static byte[] DecodeBase64Url(string encoded)
    {
        var builder = new StringBuilder(encoded)
            .Replace('-', '+')
            .Replace('_', '/');
        builder.Append('=', (4 - builder.Length % 4) % 4);
        return Convert.FromBase64String(builder.ToString());
    }
}

/// <summary>
/// 从 ~/.zcode/v2/credentials.json 读出的 GLM coding-plan 相关凭据。
/// 仓库惯例为一类型一文件；此处按任务书将本记录与其唯一生产者同文件放置（命名空间级、不嵌套）。
/// </summary>
/// <param name="JwtToken">zcodejwttoken 条目（缺失或解密失败为 null）。</param>
/// <param name="AccessToken">oauth:bigmodel:access_token 条目（缺失或解密失败为 null）。</param>
/// <param name="ApiKeys">
/// 全部 account-provider:coding-plan:*:api-key 条目，键 = 文件中的完整原键，值 = 明文；
/// 解密失败的条目不出现于此（记入 <paramref name="Errors"/>）。
/// </param>
/// <param name="Errors">单值解密失败记录（含键名，不含密文/明文材料），按 JwtToken → AccessToken → ApiKeys（键序）产出。</param>
public sealed record ZcodeCredentials(
    string? JwtToken,
    string? AccessToken,
    IReadOnlyDictionary<string, string> ApiKeys,
    IReadOnlyList<string> Errors)
{
    /// <summary>
    /// record 合成的 ToString 会打印全部属性（即明文凭据）——覆写为不泄露凭据的安全形式
    /// （先例：GlmCredential.ToString 的同因覆写）。
    /// </summary>
    public override string ToString() =>
        $"ZcodeCredentials(JwtToken={(JwtToken is null ? "null" : "set")}, "
        + $"AccessToken={(AccessToken is null ? "null" : "set")}, "
        + $"ApiKeys={ApiKeys.Count}, Errors={Errors.Count})";
}
