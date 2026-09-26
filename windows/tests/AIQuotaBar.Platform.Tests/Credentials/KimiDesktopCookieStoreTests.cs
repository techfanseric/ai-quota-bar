// 来源：无 Swift 对应（Windows 端新增——KimiDesktopCookieStore 的测试，港口依据 Win-CodexBar
// desktop_token.rs 的测试集并按仓库约定改写）。样本全部合成（无任何真实凭据）：
// 测试内用 Microsoft.Data.Sqlite 现造合成 Cookies 库（Chromium net/cookies schema 的最小子集），
// encrypted_value 用测试自造 key + 真实 DPAPI（CurrentUser 保护后写入 Local State JSON）+ AES-256-GCM
// 现做密文——即对「Local State → DPAPI → v10 AES-GCM」完整解密链的自测。
// 时间戳量纲：Chromium 的 last_access_utc / expires_utc 为自 1601-01-01T00:00:00Z 起的微秒数
// （与 Windows FILETIME 同源）；本测试按真实库数量级取值（见 ToChromiumTimestampUtc），
// 但「取最新」排序只依赖其单调性。

#nullable enable

using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using AIQuotaBar.Platform.Credentials;
using AIQuotaBar.Platform.Crypto;
using Microsoft.Data.Sqlite;
using Xunit;

namespace AIQuotaBar.Platform.Tests.Credentials;

[Trait("Category", "RequiresWindows")]
public sealed class KimiDesktopCookieStoreTests : IDisposable
{
    private const string AuthCookieName = "kimi-auth";
    private const int NonceSizeBytes = 12;
    private const int TagSizeBytes = 16;

    /// <summary>确定性的测试 key（32 字节）与 nonce（12 字节）——合成密文可复算，随机亦无碍。</summary>
    private static readonly byte[] TestAesKey = Enumerable.Range(0, 32).Select(i => (byte)(i + 7)).ToArray();
    private static readonly byte[] TestNonce = Enumerable.Range(0, NonceSizeBytes).Select(i => (byte)(i + 9)).ToArray();

    private readonly string _tempRoot;
    private readonly string _dataRoot; // %APPDATA%\kimi-desktop 的测试替身（userData 目录本身）
    private readonly DpapiProtector _dpapi = new();

    public KimiDesktopCookieStoreTests()
    {
        // setUp（§7.2）：临时根 + UUID 隔离；dataRoot 即 userData 目录（被测 ctor 语义）。
        _tempRoot = Path.Combine(Path.GetTempPath(), "aqb-kimi-cookie-" + Guid.NewGuid().ToString("N"));
        _dataRoot = Path.Combine(_tempRoot, "kimi-desktop");
        Directory.CreateDirectory(_dataRoot);
    }

    public void Dispose()
    {
        // tearDown：临时根整体清理；所有连接均已 using 释放，若删除失败即说明句柄/边车泄漏。
        Directory.Delete(_tempRoot, recursive: true);
    }

    private string CookiesPath => Path.Combine(_dataRoot, "Cookies");
    private string LocalStatePath => Path.Combine(_dataRoot, "Local State");

    private KimiDesktopCookieStore CreateStore() => new(dataRoot: _dataRoot);

    // ------------------------------------------------------------------
    // 明文行：命中、跨 host 取最新、优先于密文。
    // ------------------------------------------------------------------

    [Fact]
    public void ReadsNewestPlaintextKimiAuthTokenAcrossHosts()
    {
        WriteLocalState(TestAesKey);
        using var database = OpenCookiesDatabase();
        InsertCookie(database, "www.kimi.com", "older-token", lastAccessUtc: MinutesAgo(10));
        InsertCookie(database, ".kimi.com", "newer-token", lastAccessUtc: MinutesAgo(5));

        var token = CreateStore().TryLoadAuthToken();

        // 应然：四个注册域内 name=kimi-auth 按 last_access_utc 取最新（实然：取到旧行或 null 即失败）。
        Assert.Equal("newer-token", token);
    }

    [Fact]
    public void PrefersPlaintextColumnOverEncryptedValue()
    {
        WriteLocalState(TestAesKey);
        using var database = OpenCookiesDatabase();
        // 同一行两列都有值：Chromium 在 Windows 写密文列，但 value 列有值时上游语义即用它。
        InsertCookie(database, "www.kimi.com", "plain-wins", EncryptV10("encrypted-should-be-ignored"), MinutesAgo(1));

        var token = CreateStore().TryLoadAuthToken();

        // 应然：明文 value 列优先（实然：走了解密路径即失败——测试 key 能解开，值却应不同）。
        Assert.Equal("plain-wins", token);
    }

    // ------------------------------------------------------------------
    // 密文行：Local State → DPAPI → v10 AES-256-GCM 完整链。
    // ------------------------------------------------------------------

    [Fact]
    public void DecryptsEncryptedValueThroughLocalStateChain()
    {
        WriteLocalState(TestAesKey); // base64("DPAPI" + DPAPI(CurrentUser, TestAesKey)) → os_crypt.encrypted_key
        using var database = OpenCookiesDatabase();
        InsertCookie(database, "www.kimi.com", value: "", EncryptV10("encrypted-kimi-token"), MinutesAgo(1));

        var token = CreateStore().TryLoadAuthToken();

        // 应然：真实 DPAPI 解包 + AES-256-GCM 解密链解出原值——该值只存在于以 TestAesKey
        // 加密、且 key 又被 DPAPI 包裹的密文中，任何一环走错都只会得到 null。
        Assert.Equal("encrypted-kimi-token", token);
    }

    [Fact]
    public void SkipsBinaryHeaderInDecryptedPlaintext()
    {
        WriteLocalState(TestAesKey);
        using var database = OpenCookiesDatabase();
        // 32 字节非可打印前缀 + 真值：部分 Chromium 版本在 AES-GCM 明文前混入内部元数据，
        // 参考实现的 decrypt_chromium_cookie 会跳过该头（见被测 StripBinaryHeader）。
        var plaintext = new byte[32 + Encoding.UTF8.GetByteCount("token-after-header")];
        Array.Fill(plaintext, (byte)0xFF, 0, 32);
        Encoding.UTF8.GetBytes("token-after-header").CopyTo(plaintext, 32);
        InsertCookie(database, "www.kimi.com", value: "", EncryptV10(plaintext), MinutesAgo(1));

        var token = CreateStore().TryLoadAuthToken();

        // 应然：跳过 32 字节二进制头后取到真值（实然：直接 UTF-8 解码会得到替换字符开头的乱串）。
        Assert.Equal("token-after-header", token);
    }

    [Fact]
    public void DecryptsLegacyDpapiEncryptedValue()
    {
        WriteLocalState(TestAesKey);
        using var database = OpenCookiesDatabase();
        // 旧格式（Chromium 2014 前）：整块即 DPAPI blob，无 v10/v11/v20 前缀。
        var legacyBlob = _dpapi.Protect(Encoding.UTF8.GetBytes("legacy-dpapi-token"));
        InsertCookie(database, "kimi.com", value: "", legacyBlob, MinutesAgo(1));

        var token = CreateStore().TryLoadAuthToken();

        // 应然：无 v 前缀 → 直接 DPAPI 解开（实然：null 即旧格式回退路径缺失）。
        Assert.Equal("legacy-dpapi-token", token);
    }

    // ------------------------------------------------------------------
    // WAL 安全：活跃 WAL 可读且不 checkpoint；净关闭后的 WAL 库可读且不重建边车。
    // ------------------------------------------------------------------

    [Fact]
    public void ReadsActiveWalWithoutCheckpointingIt()
    {
        WriteLocalState(TestAesKey);
        // 写连接全程保持打开：-wal/-shm 边车在场，数据尚在 WAL 里未 checkpoint。
        using var writer = OpenCookiesDatabase();
        ExecutePragma(writer, "PRAGMA journal_mode = WAL;");
        InsertCookie(writer, "www.kimi.com", "active-wal-token", lastAccessUtc: MinutesAgo(1));
        Assert.True(File.Exists(CookiesPath + "-wal"), "活跃写入中 -wal 边车应在读取前存在。");

        var token = CreateStore().TryLoadAuthToken();

        // 应然：活跃 WAL 也能读到未 checkpoint 的已提交数据，且读取不消费/删除 WAL。
        Assert.Equal("active-wal-token", token);
        Assert.True(File.Exists(CookiesPath + "-wal"), "读取不得 checkpoint/删除活跃 -wal。");
    }

    [Fact]
    public void ReadsIdleWalDatabaseWithoutCreatingSidecars()
    {
        // 净关闭状态 = 主库头仍是 WAL、-wal/-shm 已被最后连接关闭时清掉。
        // 参考实现以「checkpoint 后复制主库到干净目录」重建该状态。
        string sourceCookies;
        using (var writer = OpenCookiesDatabase())
        {
            ExecutePragma(writer, "PRAGMA journal_mode = WAL;");
            InsertCookie(writer, "www.kimi.com", "idle-wal-token", lastAccessUtc: MinutesAgo(1));
            ExecutePragma(writer, "PRAGMA wal_checkpoint(TRUNCATE);");
            sourceCookies = writer.DataSource!;
        }

        var idleRoot = Path.Combine(_tempRoot, "idle-home", "kimi-desktop");
        Directory.CreateDirectory(idleRoot);
        File.Copy(sourceCookies, Path.Combine(idleRoot, "Cookies"));
        WriteLocalState(TestAesKey, dataRoot: idleRoot);
        var walPath = Path.Combine(idleRoot, "Cookies-wal");
        var shmPath = Path.Combine(idleRoot, "Cookies-shm");
        Assert.False(File.Exists(walPath) || File.Exists(shmPath), "前置：净关闭后无 -wal/-shm 边车。");

        var token = new KimiDesktopCookieStore(dataRoot: idleRoot).TryLoadAuthToken();

        // 应然：immutable=1 路径读出已 checkpoint 的数据（实然：普通只读打开会失败或重建边车）。
        Assert.Equal("idle-wal-token", token);
        Assert.False(File.Exists(walPath), "读取不得在用户目录重建 -wal。");
        Assert.False(File.Exists(shmPath), "读取不得在用户目录重建 -shm。");
    }

    // ------------------------------------------------------------------
    // 缺失/无匹配 → null。
    // ------------------------------------------------------------------

    [Fact]
    public void MissingCookiesDatabaseReturnsNull()
    {
        WriteLocalState(TestAesKey); // Local State 在位，Cookies 库缺失。

        var token = CreateStore().TryLoadAuthToken();

        Assert.Null(token);
    }

    [Fact]
    public void MissingLocalStateReturnsNull()
    {
        using var database = OpenCookiesDatabase();
        InsertCookie(database, "www.kimi.com", "plaintext-but-no-local-state", lastAccessUtc: MinutesAgo(1));

        var token = CreateStore().TryLoadAuthToken();

        // 应然：Local State 缺失 → null（任务书语义：库/Local State/cookie 任一缺失 → null。
        // 注：参考实现此处容忍缺失、退化为只读明文行——本移植刻意收紧，见实现文件头偏差 1）。
        Assert.Null(token);
    }

    [Fact]
    public void CorruptLocalStateReturnsNull()
    {
        using var database = OpenCookiesDatabase();
        InsertCookie(database, "www.kimi.com", value: "", EncryptV10("unreachable-token"), MinutesAgo(1));

        File.WriteAllText(LocalStatePath, "{ definitely not json");
        Assert.Null(CreateStore().TryLoadAuthToken());

        // 有 os_crypt 但无 encrypted_key 字段：同样归一为「读不到」。
        File.WriteAllText(LocalStatePath, new JsonObject { ["os_crypt"] = new JsonObject() }.ToJsonString());
        Assert.Null(CreateStore().TryLoadAuthToken());
    }

    [Fact]
    public void NoMatchingCookieReturnsNull()
    {
        using var database = OpenCookiesDatabase();
        InsertCookie(database, "example.com", "wrong-host-token", lastAccessUtc: MinutesAgo(1));
        InsertCookie(database, "www.kimi.com", "wrong-name-token", lastAccessUtc: MinutesAgo(1), name: "sessionid");

        var token = CreateStore().TryLoadAuthToken();

        // 应然：host 与 name 双重过滤后无行（实然：取到任一杂行即失败）。
        Assert.Null(token);
    }

    // ------------------------------------------------------------------
    // 畸形值 / 畸形库 / ABE / 路径注入。
    // ------------------------------------------------------------------

    [Fact]
    public void EmptyOrWhitespaceTokensAreRejected()
    {
        WriteLocalState(TestAesKey);
        using var database = OpenCookiesDatabase();
        InsertCookie(database, "kimi.com", value: "   \n ", encryptedValue: Array.Empty<byte>(), lastAccessUtc: MinutesAgo(2));
        InsertCookie(database, "kimi.com", value: "", encryptedValue: Array.Empty<byte>(), lastAccessUtc: MinutesAgo(1));

        var token = CreateStore().TryLoadAuthToken();

        // 应然：空白明文 + 空密文均不是有效 token（参考实现同判）。
        Assert.Null(token);
    }

    [Fact]
    public void MalformedDatabaseReturnsNull()
    {
        WriteLocalState(TestAesKey);
        File.WriteAllText(CookiesPath, "definitely not sqlite");

        var token = CreateStore().TryLoadAuthToken();

        // 应然：非 SQLite 文件归一为 null（不抛——只读探测语义）。
        Assert.Null(token);
    }

    [Fact]
    public void AppBoundEncryptedV20ValueReturnsNull()
    {
        WriteLocalState(TestAesKey);
        using var database = OpenCookiesDatabase();
        // v20 = Chromium App-Bound Encryption：用户态不可解，即便 Local State 完全合法。
        var v20Blob = new byte[3 + 48];
        Encoding.ASCII.GetBytes("v20").CopyTo(v20Blob, 0);
        Array.Fill(v20Blob, (byte)0x42, 3, 48);
        InsertCookie(database, "www.kimi.com", value: "", v20Blob, MinutesAgo(1));

        var token = CreateStore().TryLoadAuthToken();

        Assert.Null(token);
    }

    [Fact]
    public void ExplicitPathOverridesBeatDataRoot()
    {
        using var database = OpenCookiesDatabase();
        InsertCookie(database, "www.kimi.com", "explicit-paths-token", lastAccessUtc: MinutesAgo(1));
        WriteLocalState(TestAesKey);

        // dataRoot 指向不存在的目录；显式 cookiesPath/localStatePath 必须胜出。
        var store = new KimiDesktopCookieStore(
            dataRoot: Path.Combine(_tempRoot, "bogus-root"),
            cookiesPath: CookiesPath,
            localStatePath: LocalStatePath);

        // 应然：显式路径注入生效（实然：仍按 dataRoot 拼路径即得到 null）。
        Assert.Equal("explicit-paths-token", store.TryLoadAuthToken());
    }

    // ------------------------------------------------------------------
    // 合成库与密文的构造辅助。
    // ------------------------------------------------------------------

    /// <summary>开一个可写连接并建好 Chromium cookies 表的最小 schema（含被读的 5 列及其近邻）。</summary>
    private SqliteConnection OpenCookiesDatabase()
    {
        // Pooling=false：Dispose 即关闭原生句柄，tearDown 的目录删除不会被池化连接锁住。
        var connection = new SqliteConnection(
            new SqliteConnectionStringBuilder { DataSource = CookiesPath, Pooling = false }.ToString());
        connection.Open();

        using var command = connection.CreateCommand();
        command.CommandText = """
            CREATE TABLE cookies (
                creation_utc     INTEGER NOT NULL DEFAULT 0,
                host_key         TEXT    NOT NULL,
                name             TEXT    NOT NULL,
                value            TEXT    NOT NULL,
                path             TEXT    NOT NULL DEFAULT '/',
                encrypted_value  BLOB    NOT NULL DEFAULT X'',
                expires_utc      INTEGER NOT NULL,
                is_secure        INTEGER NOT NULL DEFAULT 0,
                is_httponly      INTEGER NOT NULL DEFAULT 0,
                last_access_utc  INTEGER NOT NULL,
                has_expires      INTEGER NOT NULL DEFAULT 1,
                is_persistent    INTEGER NOT NULL DEFAULT 1
            )
            """;
        command.ExecuteNonQuery();
        return connection;
    }

    private static void InsertCookie(
        SqliteConnection connection,
        string hostKey,
        string value,
        byte[]? encryptedValue = null,
        long? lastAccessUtc = null,
        string name = AuthCookieName)
    {
        using var command = connection.CreateCommand();
        command.CommandText = """
            INSERT INTO cookies (host_key, name, value, encrypted_value, last_access_utc, expires_utc)
            VALUES ($host, $name, $value, $encrypted, $lastAccess, $expires)
            """;
        command.Parameters.AddWithValue("$host", hostKey);
        command.Parameters.AddWithValue("$name", name);
        command.Parameters.AddWithValue("$value", value);
        command.Parameters.AddWithValue("$encrypted", encryptedValue ?? Array.Empty<byte>());
        command.Parameters.AddWithValue("$lastAccess", lastAccessUtc ?? MinutesAgo(1));
        command.Parameters.AddWithValue("$expires", ToChromiumTimestampUtc(DateTime.UtcNow.AddDays(30)));
        command.ExecuteNonQuery();
    }

    private static void ExecutePragma(SqliteConnection connection, string pragma)
    {
        using var command = connection.CreateCommand();
        command.CommandText = pragma;
        command.ExecuteNonQuery();
    }

    /// <summary>写与真实 Chromium 同构的 Local State：os_crypt.encrypted_key = base64("DPAPI" + DPAPI blob)。</summary>
    private void WriteLocalState(byte[] aesKey, string? dataRoot = null)
    {
        var dpapiBlob = _dpapi.Protect(aesKey); // CurrentUser 作用域：SSH 会话可用（区别于 Credential Manager）
        var prefixed = new byte[DpapiKeyPrefixLength + dpapiBlob.Length];
        Encoding.ASCII.GetBytes("DPAPI").CopyTo(prefixed, 0);
        dpapiBlob.CopyTo(prefixed, DpapiKeyPrefixLength);

        var path = dataRoot is null ? LocalStatePath : Path.Combine(dataRoot, "Local State");
        File.WriteAllText(
            path,
            new JsonObject
            {
                ["os_crypt"] = new JsonObject { ["encrypted_key"] = Convert.ToBase64String(prefixed) },
            }.ToJsonString());
    }

    private const int DpapiKeyPrefixLength = 5;

    /// <summary>现做 v10 密文：3 字节前缀 + 12 字节 nonce + 密文 + 16 字节 tag（AES-256-GCM，无 AAD）。</summary>
    private static byte[] EncryptV10(string plaintext) => EncryptV10(Encoding.UTF8.GetBytes(plaintext));

    private static byte[] EncryptV10(byte[] plaintext)
    {
        using var cipher = new AesGcm(TestAesKey, TagSizeBytes);
        var ciphertext = new byte[plaintext.Length];
        var tag = new byte[TagSizeBytes];
        cipher.Encrypt(TestNonce, plaintext, ciphertext, tag);

        var blob = new byte[3 + NonceSizeBytes + ciphertext.Length + TagSizeBytes];
        Encoding.ASCII.GetBytes("v10").CopyTo(blob, 0);
        TestNonce.CopyTo(blob, 3);
        ciphertext.CopyTo(blob, 3 + NonceSizeBytes);
        tag.CopyTo(blob, blob.Length - TagSizeBytes);
        return blob;
    }

    private static long MinutesAgo(int minutes) => ToChromiumTimestampUtc(DateTime.UtcNow.AddMinutes(-minutes));

    /// <summary>
    /// Chromium 时间戳：自 1601-01-01T00:00:00Z 起的微秒数（与 Windows FILETIME 同源）。
    /// last_access_utc / expires_utc 均用该量纲；排序语义只依赖单调性，取真实量纲是为贴近真实库。
    /// </summary>
    private static long ToChromiumTimestampUtc(DateTime utc)
    {
        var chromiumEpoch = new DateTime(1601, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        return (long)utc.Subtract(chromiumEpoch).TotalMicroseconds;
    }
}
