// 来源：无 Swift 对应（Windows 端新增——MinimaxCliCredentialReader 的测试）。
// config.json 为 mcode CLI 的本地配置文件格式（测试合成，非 API 响应，无需 fixtures——先例：
// ZcodeCredentialStoreTests 的合成 credentials.json）。全部样例均为凭空合成，不含任何真实凭据。
// 路径注入：每个被测 Reader 的主/次路径都显式注入（次路径指向不存在文件），避免默认解析读到
// 真机用户的 %USERPROFILE%\.minimax\config.json 造成测试环境耦合。

using AIQuotaBar.Providers.Minimax;
using Xunit;

namespace AIQuotaBar.Providers.Tests.Minimax;

public sealed class MinimaxCliCredentialReaderTests
{
    // ------------------------------------------------------------------
    // 正常读取。
    // ------------------------------------------------------------------

    [Fact]
    public void ValidConfig_ReturnsApiKeyAndGroupId()
    {
        using var file = TempConfigFile.WithJson(
            """{"api_key":"eyJhbGciOiJFUzI1NiJ9.synthetic-mcode-key","group_id":"1745029837"}""");

        var credentials = ReaderAt(file.ConfigPath).TryLoad();

        Assert.NotNull(credentials);
        // 应然：api_key 与 group_id 均按文件原值读出（实然：缺字段/错值即失败）。
        Assert.Equal("eyJhbGciOiJFUzI1NiJ9.synthetic-mcode-key", credentials!.ApiKey);
        Assert.Equal("1745029837", credentials.GroupId);
    }

    [Fact]
    public void SurroundingWhitespace_IsTrimmed()
    {
        using var file = TempConfigFile.WithJson("""{"api_key":"  synthetic-key  ","group_id":"\t1745029837 \n"}""");

        var credentials = ReaderAt(file.ConfigPath).TryLoad();

        Assert.NotNull(credentials);
        // 应然：两字段均存 trim 后的值（MinimaxClient 侧同款规整）。
        Assert.Equal("synthetic-key", credentials!.ApiKey);
        Assert.Equal("1745029837", credentials.GroupId);
    }

    [Fact]
    public void MissingGroupId_ReturnsNullGroupWithApiKey()
    {
        using var file = TempConfigFile.WithJson("""{"api_key":"synthetic-key"}""");

        var credentials = ReaderAt(file.ConfigPath).TryLoad();

        Assert.NotNull(credentials);
        // 应然：group_id 可选——缺失时 GroupId 为 null，ApiKey 照常可用（remains 端点只需 Bearer api_key）。
        Assert.Equal("synthetic-key", credentials!.ApiKey);
        Assert.Null(credentials.GroupId);
    }

    [Fact]
    public void UnknownFields_AreIgnored()
    {
        using var file = TempConfigFile.WithJson(
            """{"api_key":"synthetic-key","group_id":"1745029837","base_url":"https://api.minimax.io","nested":{"a":1}}""");

        var credentials = ReaderAt(file.ConfigPath).TryLoad();

        Assert.NotNull(credentials);
        // 应然：mcode 写入的其他字段不影响读取（未知字段容忍，System.Text.Json 默认行为钉住）。
        Assert.Equal("synthetic-key", credentials!.ApiKey);
        Assert.Equal("1745029837", credentials.GroupId);
    }

    // ------------------------------------------------------------------
    // 文件缺失 / 坏 JSON / 缺 api_key → null。
    // ------------------------------------------------------------------

    [Fact]
    public void MissingFile_ReturnsNull()
    {
        var reader = new MinimaxCliCredentialReader(TempConfigFile.MissingPath(), TempConfigFile.MissingPath());

        // 应然：主/次路径文件均不存在返回 null，不抛异常（Try 语义）。
        Assert.Null(reader.TryLoad());
    }

    [Theory]
    [InlineData("not json {")]
    [InlineData("[]")]      // 根不是对象
    [InlineData("42")]      // 根不是对象
    public void MalformedJson_ReturnsNull(string contents)
    {
        using var file = TempConfigFile.WithJson(contents);
        var reader = new MinimaxCliCredentialReader(file.ConfigPath, TempConfigFile.MissingPath());

        // 应然：坏 JSON / 根非对象一律 null（实然：抛异常即失败）。
        Assert.Null(reader.TryLoad());
    }

    [Theory]
    [InlineData("{}")]                          // 空对象：无任何凭据字段
    [InlineData("""{"group_id":"1745029837"}""")] // 只有 group_id，缺必需的 api_key
    [InlineData("""{"api_key":"   "}""")]        // api_key 空白：视为缺失
    [InlineData("""{"api_key":123}""")]          // api_key 非字符串：按缺失处理（Win-CodexBar as_str 同款）
    public void MissingOrBlankApiKey_ReturnsNull(string contents)
    {
        using var file = TempConfigFile.WithJson(contents);
        var reader = new MinimaxCliCredentialReader(file.ConfigPath, TempConfigFile.MissingPath());

        // 应然：无可用 api_key 即整体 null——api_key 是唯一必需字段，空白/非字符串不算数。
        Assert.Null(reader.TryLoad());
    }

    [Fact]
    public void BlankGroupId_IsTreatedAsMissing()
    {
        using var file = TempConfigFile.WithJson("""{"api_key":"synthetic-key","group_id":"   "}""");

        var credentials = ReaderAt(file.ConfigPath).TryLoad();

        Assert.NotNull(credentials);
        // 应然：空白 group_id 与缺失同义（GroupId 为 null），不拖垮 api_key。
        Assert.Equal("synthetic-key", credentials!.ApiKey);
        Assert.Null(credentials.GroupId);
    }

    // ------------------------------------------------------------------
    // 主/次路径解析次序（注入两个路径钉住默认解析的回退语义）。
    // ------------------------------------------------------------------

    [Fact]
    public void PrimaryConfig_TakesPrecedenceOverLegacy()
    {
        using var primary = TempConfigFile.WithJson("""{"api_key":"synthetic-primary-key"}""");
        using var legacy = TempConfigFile.WithJson("""{"api_key":"synthetic-legacy-key"}""");
        var reader = new MinimaxCliCredentialReader(primary.ConfigPath, legacy.ConfigPath);

        var credentials = reader.TryLoad();

        Assert.NotNull(credentials);
        // 应然：两路径都有可用凭据时取主路径（%APPDATA%\minimax），次选只做兜底。
        Assert.Equal("synthetic-primary-key", credentials!.ApiKey);
    }

    [Fact]
    public void MissingPrimary_FallsBackToLegacy()
    {
        using var legacy = TempConfigFile.WithJson(
            """{"api_key":"synthetic-legacy-key","group_id":"1745029837"}""");
        var reader = new MinimaxCliCredentialReader(TempConfigFile.MissingPath(), legacy.ConfigPath);

        var credentials = reader.TryLoad();

        Assert.NotNull(credentials);
        // 应然：主路径文件缺失时回退次选（%USERPROFILE%\.minimax），凭据照常读出。
        Assert.Equal("synthetic-legacy-key", credentials!.ApiKey);
        Assert.Equal("1745029837", credentials.GroupId);
    }

    [Fact]
    public void UnusablePrimary_FallsBackToLegacy()
    {
        // 主路径存在但 api_key 不可用（坏 JSON 同理）：不算“已有凭据”，继续尝试次选。
        using var primary = TempConfigFile.WithJson("""{"group_id":"1745029837"}""");
        using var legacy = TempConfigFile.WithJson("""{"api_key":"synthetic-legacy-key"}""");
        var reader = new MinimaxCliCredentialReader(primary.ConfigPath, legacy.ConfigPath);

        var credentials = reader.TryLoad();

        Assert.NotNull(credentials);
        // 应然：主路径无可用 api_key 时回退次选，而不是整体 null。
        Assert.Equal("synthetic-legacy-key", credentials!.ApiKey);
    }

    // ------------------------------------------------------------------
    // 默认路径形状（纯常量拼装，不真读盘；Win-CodexBar get_minimax_config_path 结论）。
    // ------------------------------------------------------------------

    [Fact]
    public void DefaultConfigPath_IsRoamingMinimaxConfigJson()
    {
        var path = MinimaxCliCredentialReader.DefaultConfigPath();

        // 应然：%APPDATA%\minimax\config.json——等于漫游 AppData 目录 + minimax 段 + 文件名
        //（实然：落到 LocalApplicationData / 用户根等其他目录即失败）。
        Assert.Equal(
            Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "minimax",
                "config.json"),
            path);
        Assert.Equal("minimax", Path.GetFileName(Path.GetDirectoryName(path)));
        Assert.Equal("config.json", Path.GetFileName(path));
    }

    [Fact]
    public void LegacyConfigPath_IsHomeDotMinimaxConfigJson()
    {
        var path = MinimaxCliCredentialReader.LegacyConfigPath();

        // 应然：%USERPROFILE%\.minimax\config.json——Win-CodexBar 非 Windows 约定（~/.minimax）
        // 的 home 目录映射，作为主路径不存在时的次选。
        Assert.Equal(
            Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".minimax",
                "config.json"),
            path);
        Assert.Equal(".minimax", Path.GetFileName(Path.GetDirectoryName(path)));
        Assert.Equal("config.json", Path.GetFileName(path));
    }

    // ------------------------------------------------------------------
    // 测试辅助：临时 config.json（Path.GetTempPath + UUID 文件名；IDisposable 清理，
    // 对应 Swift setUp/tearDown；先例：ZcodeCredentialStoreTests.TempCredentialsFile）。
    // ------------------------------------------------------------------

    /// <summary>主路径指向临时文件、次路径指向不存在文件的 Reader（默认解析的“单路径”视图）。</summary>
    private static MinimaxCliCredentialReader ReaderAt(string configPath) =>
        new(configPath, TempConfigFile.MissingPath());

    private sealed class TempConfigFile : IDisposable
    {
        public string ConfigPath { get; }

        private TempConfigFile(string path)
        {
            ConfigPath = path;
        }

        public static TempConfigFile WithJson(string json)
        {
            var path = Path.Combine(
                Path.GetTempPath(),
                "aiqb-minimax-mcode-tests-" + Guid.NewGuid().ToString("N") + ".json");
            File.WriteAllText(path, json);
            return new TempConfigFile(path);
        }

        /// <summary>指向不存在的文件（父目录也不存在），供“文件缺失”用例与次路径占位。</summary>
        public static string MissingPath() =>
            Path.Combine(
                Path.GetTempPath(),
                "aiqb-minimax-mcode-tests-" + Guid.NewGuid().ToString("N"),
                "config.json");

        public void Dispose()
        {
            try
            {
                File.Delete(ConfigPath);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // 清理失败不影响测试结果。
            }
        }
    }
}
