// Swift 来源：无（Windows 端新增；Kimi Desktop 数据源，macOS 端由上游 AIQuotaBar 自读、无对应读取器）
// 港口依据：nesszer/Win-CodexBar @ b585d48（2026-09-23，已在 Windows 实机验证的开源实现），
// 按其语义 1:1 移植、不再自行探索：
//   - rust/src/providers/kimi/desktop_token.rs：目标 cookie（name=kimi-auth，四个 kimi.com 域、
//     取 last_access_utc 最新）、value/encrypted_value 解码顺序、只读探测语义；
//   - rust/src/core/sqlite.rs：WAL 安全只读打开策略（绝不创建/改动 -wal、-shm 边车）；
//   - rust/src/browser/cookies.rs：Chromium Windows 密钥链（Local State → DPAPI → AES-256-GCM v10）。
// 对应测试：windows/tests/AIQuotaBar.Platform.Tests/Credentials/KimiDesktopCookieStoreTests.cs
//
// 布局与解密链（Win-CodexBar 已验证）：
// - 库位置 %APPDATA%\kimi-desktop（Roaming——Electron userData；上游 macOS 同布局）下：
//   Cookies（SQLite）与 Local State（JSON）同目录。
// - 明文 value 列优先；为空则解 encrypted_value：Chromium Windows v10/v11 格式 =
//   "v10" 前缀（3 字节）+ 12 字节 nonce + 密文 + 16 字节 tag（AES-256-GCM，无 AAD）。
// - key 来自 Local State 的 os_crypt.encrypted_key：base64 解码后为 "DPAPI" 5 字节前缀 +
//   DPAPI blob，CurrentUser 解开得 32 字节 key（复用 Crypto/DpapiProtector）。
// - v20 前缀 = Chromium App-Bound Encryption（ABE），用户态不可解 → 视作读不到（null）；
//   无 v 前缀的旧格式 = 整块 DPAPI blob，直接 Unprotect（参考实现同路径）。
//
// 与参考实现的三处刻意偏差（均已注明理由）：
// 1. Local State 必须在位：参考实现容忍其缺失（退化为只读明文行）；本移植按任务书语义收紧为
//    库/Local State/cookie 任一缺失 → null。实际装机中 Kimi Desktop（Chromium）首次运行必写
//    Local State，两种语义仅在「应用从未运行」场景重合为 null。
// 2. 未移植 is_expired_jwt 过滤（参考实现用它避免过期桌面 JWT 遮蔽浏览器会话）：任务书未列，
//    且 token 生命周期判定属于 Kimi provider 的多源决策，不在本读取器职责内。
// 3. Microsoft.Data.Sqlite（8.x）没有 Immutable 连接串关键字（SqliteConnectionStringBuilder 会抛
//    ArgumentException），rusqlite 的 immutable=1 回退以 Data Source=file:<绝对路径>?immutable=1
//    的 SQLite URI 形式等价实现——SqliteConnectionInternal 对 file: 前缀自动附加 SQLITE_OPEN_URI
//    （对齐参考实现 sqlite_immutable_uri 的路径归一）。
// 另附加 Pooling=False（探测完即释放文件句柄，不驻留用户 Cookie 库）与 Default Timeout=1 秒
// （对齐参考实现 250ms busy timeout 的短探测语义，避免 Kimi Desktop checkpoint 时卡住刷新）。
//
// 机密纪律：token 值绝不进日志/异常消息/ToString（本类不持有 token 状态、不写日志）。

#nullable enable

using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using AIQuotaBar.Platform.Crypto;
using Microsoft.Data.Sqlite;

namespace AIQuotaBar.Platform.Credentials;

/// <summary>
/// 只读探测 Kimi Desktop（Chromium/Electron）登录会话的 kimi-auth cookie。
/// </summary>
/// <remarks>
/// 生产语义：<see cref="TryLoadAuthToken"/> 返回最近访问的 kimi-auth token；Cookies 库、
/// Local State、目标 cookie 任一缺失，或全程任何异常（坏 JSON、tag 校验失败、非 SQLite 文件……）
/// 均返回 null——只读探测，不向调用方抛。打开库采用 WAL 安全策略：边车缺失时优先
/// immutable=1 URI 只读（净关闭后主库头仍是 WAL 的库，普通只读打开会在用户目录里重建
/// -shm/-wal），否则普通只读；普通只读打不开且边车缺失时回退 immutable。绝不写边车。
/// </remarks>
public sealed class KimiDesktopCookieStore
{
    private const string DesktopAppDirectoryName = "kimi-desktop";
    private const string CookiesFileName = "Cookies";
    private const string LocalStateFileName = "Local State";
    private const string AuthCookieName = "kimi-auth";

    /// <summary>参考实现 AUTH_COOKIE_HOSTS 原序：www → .www → 裸域两态。</summary>
    private static readonly string[] AuthCookieHosts =
        ["www.kimi.com", ".www.kimi.com", ".kimi.com", "kimi.com"];

    /// <summary>Local State 中 DPAPI blob 的 5 字节明文前缀（base64 解码后）。</summary>
    private static readonly byte[] DpapiKeyPrefix = Encoding.ASCII.GetBytes("DPAPI");

    /// <summary>解出明文必须是合法 UTF-8：参考实现 from_utf8 失败即弃，BCL 默认替换 U+FFFD 过于宽松。</summary>
    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    private const int AesKeySizeBytes = 32;
    private const int NonceSizeBytes = 12;
    private const int TagSizeBytes = 16;

    /// <summary>v10/v11 最短密文长度：3 前缀 + 12 nonce + 16 tag（密文可为空）；更短的 "v10…" 按旧 DPAPI 格式处理。</summary>
    private const int MinV10EncryptedValueBytes = 3 + NonceSizeBytes + TagSizeBytes;

    /// <summary>参考实现 decrypt_chromium_cookie 的二进制头跳过宽度（部分 Chromium 版本在 AES-GCM 明文前混入内部元数据）。</summary>
    private const int BinaryHeaderSizeBytes = 32;

    private const string WalSidecarSuffix = "-wal";
    private const string ShmSidecarSuffix = "-shm";
    private const int ProbeCommandTimeoutSeconds = 1;

    /// <summary>Windows 长路径前缀（Path.GetFullPath 对超长注入路径可能保留）：SQLite URI 解析不接受。</summary>
    private static readonly string LongPathPrefix = @"\\?\";

    private const string SelectNewestAuthCookieSql = """
        SELECT value, encrypted_value
        FROM cookies
        WHERE name = $name
          AND host_key IN ($host0, $host1, $host2, $host3)
        ORDER BY last_access_utc DESC
        LIMIT 1
        """;

    private readonly string _cookiesPath;
    private readonly string _localStatePath;
    private readonly DpapiProtector _dpapi = new();

    /// <param name="dataRoot">
    /// Kimi Desktop 的 userData 目录；null 时用 %APPDATA%\kimi-desktop（Roaming）。
    /// </param>
    /// <param name="cookiesPath">Cookies 库完整路径；null 时拼 <paramref name="dataRoot"/>（测试注入）。</param>
    /// <param name="localStatePath">Local State 完整路径；null 时拼 <paramref name="dataRoot"/>（测试注入）。</param>
    public KimiDesktopCookieStore(
        string? dataRoot = null,
        string? cookiesPath = null,
        string? localStatePath = null)
    {
        var root = dataRoot ?? DefaultDataRoot();
        _cookiesPath = cookiesPath ?? Path.Combine(root, CookiesFileName);
        _localStatePath = localStatePath ?? Path.Combine(root, LocalStateFileName);
    }

    /// <summary>
    /// 读取最近访问的 kimi-auth token。Cookies 库 / Local State / 目标 cookie 任一缺失，
    /// 或全程任何异常 → null（只读探测语义，不抛）。token 值不进任何日志。
    /// </summary>
    public string? TryLoadAuthToken()
    {
        try
        {
            // 先决条件：两文件都在位（比参考实现严：明文行也要求 Local State，见文件头偏差 1）。
            if (!File.Exists(_cookiesPath) || !File.Exists(_localStatePath))
            {
                return null;
            }

            var aesKey = TryLoadChromiumAesKey();
            if (aesKey is null)
            {
                return null;
            }

            using var connection = TryOpenReadOnly();
            if (connection is null)
            {
                return null;
            }

            var row = ReadNewestAuthCookie(connection);
            if (row is null)
            {
                return null;
            }

            return DecodeCookieValue(row.Value.Value, row.Value.EncryptedValue, aesKey);
        }
        catch (Exception)
        {
            // 全程任何异常 → null：探测语义优先于诊断（坏 JSON、tag 校验失败、非 SQLite 文件、
            // DPAPI 拒解……均归一为「读不到」），且异常消息可能携带路径等敏感上下文。
            return null;
        }
    }

    private static string DefaultDataRoot() =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            DesktopAppDirectoryName);

    // ------------------------------------------------------------------
    // Local State → DPAPI → AES key。
    // ------------------------------------------------------------------

    /// <summary>
    /// Local State 的 os_crypt.encrypted_key：base64 → 剥 "DPAPI" 前缀 → CurrentUser DPAPI 解开。
    /// 任何一步不合期望（字段缺失、前缀不对、解出的不是 32 字节）→ null。
    /// </summary>
    private byte[]? TryLoadChromiumAesKey()
    {
        var contents = File.ReadAllText(_localStatePath);

        if (JsonNode.Parse(contents) is not JsonObject root ||
            root["os_crypt"]?["encrypted_key"] is not JsonValue encodedKeyValue ||
            !encodedKeyValue.TryGetValue<string>(out var encodedKey))
        {
            return null;
        }

        var encryptedKey = Convert.FromBase64String(encodedKey);
        if (encryptedKey.Length < DpapiKeyPrefix.Length ||
            !encryptedKey.AsSpan(0, DpapiKeyPrefix.Length).SequenceEqual(DpapiKeyPrefix))
        {
            return null;
        }

        var key = _dpapi.Unprotect(encryptedKey[DpapiKeyPrefix.Length..]);
        return key.Length == AesKeySizeBytes ? key : null;
    }

    // ------------------------------------------------------------------
    // WAL 安全只读打开（参考 core/sqlite.rs 的三段策略）。
    // ------------------------------------------------------------------

    /// <summary>
    /// 只读打开 Cookies 库，绝不创建 -wal/-shm 边车：
    /// 1. 边车缺失时优先 immutable=1 URI（净关闭后的 WAL 库直接按已 checkpoint 内容读，
    ///    普通只读打开反而会在用户目录里重建边车）；
    /// 2. 否则普通只读（活跃 WAL 依赖既有 -shm，读不 checkpoint）；
    /// 3. 普通只读以 SQLITE_CANTOPEN 失败且边车缺失时回退 immutable。
    /// 打不开 → null。
    /// </summary>
    private SqliteConnection? TryOpenReadOnly()
    {
        if (WalSidecarsMissing())
        {
            var immutable = TryOpen(BuildConnectionString(BuildImmutableDataSource(_cookiesPath)));
            if (immutable is not null)
            {
                return immutable;
            }
        }

        try
        {
            return OpenConnection(BuildConnectionString(_cookiesPath));
        }
        catch (SqliteException ex) when (IsSqliteUnableToOpen(ex) && WalSidecarsMissing())
        {
            return TryOpen(BuildConnectionString(BuildImmutableDataSource(_cookiesPath)));
        }
    }

    private static SqliteConnection? TryOpen(string connectionString)
    {
        try
        {
            return OpenConnection(connectionString);
        }
        catch (SqliteException)
        {
            return null;
        }
    }

    private static SqliteConnection OpenConnection(string connectionString)
    {
        var connection = new SqliteConnection(connectionString);
        try
        {
            connection.Open();
            return connection;
        }
        catch
        {
            connection.Dispose();
            throw;
        }
    }

    /// <summary>统一只读连接串：Mode=ReadOnly、不池化、1 秒探测超时（理由见文件头）。</summary>
    private static string BuildConnectionString(string dataSource) =>
        new SqliteConnectionStringBuilder
        {
            DataSource = dataSource,
            Mode = SqliteOpenMode.ReadOnly,
            DefaultTimeout = ProbeCommandTimeoutSeconds,
            Pooling = false,
        }.ToString();

    /// <summary>
    /// <c>file:&lt;绝对路径&gt;?immutable=1</c> 的 SQLite URI（Microsoft.Data.Sqlite 8.x 无 Immutable
    /// 关键字，见文件头偏差 3）。对齐参考 sqlite_immutable_uri：转绝对路径、剥 Windows 长路径
    /// \\?\ 前缀、反斜杠归一为正斜杠，驱动器号得以保留。
    /// </summary>
    private static string BuildImmutableDataSource(string databasePath)
    {
        var absolute = Path.GetFullPath(databasePath);
        if (absolute.StartsWith(LongPathPrefix, StringComparison.Ordinal))
        {
            absolute = absolute[LongPathPrefix.Length..];
        }

        return $"file:{absolute.Replace('\\', '/')}?immutable=1";
    }

    private bool WalSidecarsMissing() =>
        !File.Exists(_cookiesPath + WalSidecarSuffix) &&
        !File.Exists(_cookiesPath + ShmSidecarSuffix);

    /// <summary>SQLITE_CANTOPEN 判定：基码 14（扩展码低 8 位为基码）；文本兜底对齐参考实现（部分构建里错误码被文本包裹）。</summary>
    private static bool IsSqliteUnableToOpen(SqliteException exception)
    {
        const int SqliteCannotOpenBaseCode = 14;
        return (exception.SqliteErrorCode & 0xFF) == SqliteCannotOpenBaseCode ||
            exception.Message.Contains("unable to open", StringComparison.OrdinalIgnoreCase);
    }

    // ------------------------------------------------------------------
    // 目标行读取与解码。
    // ------------------------------------------------------------------

    /// <summary>上游查询原样：四个 kimi.com 域内 name=kimi-auth，按 last_access_utc 取最新一行。</summary>
    private static (string Value, byte[] EncryptedValue)? ReadNewestAuthCookie(SqliteConnection connection)
    {
        using var command = connection.CreateCommand();
        command.CommandText = SelectNewestAuthCookieSql;
        command.Parameters.AddWithValue("$name", AuthCookieName);
        for (var i = 0; i < AuthCookieHosts.Length; i++)
        {
            command.Parameters.AddWithValue($"$host{i}", AuthCookieHosts[i]);
        }

        using var reader = command.ExecuteReader();
        if (!reader.Read())
        {
            return null;
        }

        return (reader.GetString(0), reader.GetFieldValue<byte[]>(1));
    }

    /// <summary>
    /// 解码 (value, encrypted_value)：明文列优先（trim 后非空即用）；否则解密
    /// encrypted_value。两者都拿不出有效值（空白/空密文/解密失败）→ null。
    /// </summary>
    private string? DecodeCookieValue(string value, byte[] encryptedValue, byte[] aesKey)
    {
        var trimmed = value.Trim();
        if (trimmed.Length > 0)
        {
            return trimmed;
        }

        var decrypted = DecryptChromiumCookieValue(encryptedValue, aesKey)?.Trim();
        return string.IsNullOrEmpty(decrypted) ? null : decrypted;
    }

    /// <summary>
    /// 解 Chromium Windows 密文 cookie 值：v20（ABE，用户态不可解）→ null；
    /// v10/v11（≥31 字节）→ AES-256-GCM；其余 → 整块 DPAPI 旧格式。失败 → null。
    /// </summary>
    private string? DecryptChromiumCookieValue(byte[] encryptedValue, byte[] aesKey)
    {
        if (encryptedValue.Length == 0)
        {
            return null;
        }

        var prefix = encryptedValue.Length >= 3
            ? Encoding.ASCII.GetString(encryptedValue, 0, 3)
            : string.Empty;
        var hasV20Prefix = prefix == "v20";
        var hasV10OrV11Prefix = prefix is "v10" or "v11" && encryptedValue.Length >= MinV10EncryptedValueBytes;

        if (hasV20Prefix)
        {
            // Chromium App-Bound Encryption：系统级密钥，本进程（用户态、非 Kimi Desktop 本体）
            // 无法解——按「读不到」处理，不误报为格式错误（参考实现同判）。
            return null;
        }

        if (!hasV10OrV11Prefix)
        {
            // 旧格式：整块即 DPAPI blob（Chromium 2014 前的 cookie 值形态）。
            return StrictUtf8.GetString(_dpapi.Unprotect(encryptedValue));
        }

        // v10/v11：3 字节前缀 + 12 字节 nonce + 密文 + 16 字节 tag（tag 在末尾）。
        var nonce = encryptedValue[3..(3 + NonceSizeBytes)];
        var tag = encryptedValue[^TagSizeBytes..];
        var ciphertext = encryptedValue[(3 + NonceSizeBytes)..^TagSizeBytes];

        using var cipher = new AesGcm(aesKey, TagSizeBytes); // 显式 tagSizeInBytes：SYSLIB0053 合规（先例：ZcodeCredentialStore）
        var plaintext = new byte[ciphertext.Length];
        cipher.Decrypt(nonce, ciphertext, tag, plaintext); // tag 校验失败 → CryptographicException → 探测 null

        return StrictUtf8.GetString(StripBinaryHeader(plaintext));
    }

    /// <summary>
    /// 部分 Chromium 版本在 AES-GCM 明文前混入最多 32 字节的内部元数据：明文超过 32 字节且
    /// 前 32 字节含非可打印 ASCII 时，跳到首个疑似值起始字节（字母数字/"/{）与 32 字节中较大者。
    /// 参考 decrypt_chromium_cookie 同逻辑 1:1 移植（对干净的 v10 明文是恒等变换）。
    /// </summary>
    private static byte[] StripBinaryHeader(byte[] plaintext)
    {
        if (plaintext.Length <= BinaryHeaderSizeBytes)
        {
            return plaintext;
        }

        var hasBinaryPrefix = false;
        for (var i = 0; i < BinaryHeaderSizeBytes; i++)
        {
            if (plaintext[i] is < 32 or > 127)
            {
                hasBinaryPrefix = true;
                break;
            }
        }

        if (!hasBinaryPrefix)
        {
            return plaintext;
        }

        var valueStart = Array.FindIndex(
            plaintext,
            b => char.IsAsciiLetterOrDigit((char)b) || b is (byte)'"' or (byte)'{');
        if (valueStart < 0)
        {
            valueStart = 0;
        }

        // 参考：start < 32 时仍取 32（头部的字母数字属于元数据而非 cookie 值）。
        var actualStart = valueStart < BinaryHeaderSizeBytes ? BinaryHeaderSizeBytes : valueStart;
        return plaintext[actualStart..];
    }
}
