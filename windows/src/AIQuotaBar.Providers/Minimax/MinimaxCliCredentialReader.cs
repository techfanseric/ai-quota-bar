// Swift 来源：无（Windows 端新增）。数据源：mcode CLI 登录后生成的配置文件 config.json——
// Windows 路径结论取自 Win-CodexBar（github.com/nesszer/Win-CodexBar）rust/src/providers/minimax/
// mod.rs 的 get_minimax_config_path：Windows 用 dirs::config_dir() 即 %APPDATA%\minimax，非 Windows
// 用 ~/.minimax；本读取器以前者为主路径、%USERPROFILE%\.minimax\config.json 为次选（mcode 的两种
// 目录约定都覆盖）。文件为 JSON 对象，字段 api_key（字符串，登录后生成）与 group_id（字符串，可选）。
// macOS 端 AIQuotaBar 不读 mcode 配置，故无 Swift 对应。零平台依赖（纯 BCL）。
// 对应测试：AIQuotaBar.Providers.Tests/Minimax/MinimaxCliCredentialReaderTests.cs。
//
// 用途：MiniMax coding-plan remains 端点只需 Authorization: Bearer <api_key>（不需要 group_id、
// 不需要 cookie，端点族见 MinimaxClient），因此 mcode 登录后本读取器即可让 QuotaService 零配置
// 出数——凭据优先级：Credential Manager 手动配置（设置窗）→ 本读取器（先例：FetchGlmAsync 的
// ZcodeCredentialStore 回退）。

using System.Text.Json.Nodes;

namespace AIQuotaBar.Providers.Minimax;

/// <summary>
/// 读取 mcode CLI 登录生成的 config.json（api_key / group_id）。主/次路径均可注入
/// （先例：ZcodeCredentialStore 的路径注入风格），默认主路径无可用凭据时依次尝试次选路径。
/// </summary>
public sealed class MinimaxCliCredentialReader
{
    private readonly string _configPath;
    private readonly string _legacyConfigPath;

    /// <param name="configPath">主配置文件完整路径；null 时用 %APPDATA%\minimax\config.json（测试注入临时文件）。</param>
    /// <param name="legacyConfigPath">次选配置文件完整路径；null 时用 %USERPROFILE%\.minimax\config.json（测试须一并注入，避免读到真机用户配置）。</param>
    public MinimaxCliCredentialReader(string? configPath = null, string? legacyConfigPath = null)
    {
        _configPath = configPath ?? DefaultConfigPath();
        _legacyConfigPath = legacyConfigPath ?? LegacyConfigPath();
    }

    /// <summary>主配置路径：Win-CodexBar minimax provider 的 Windows 结论（dirs::config_dir → %APPDATA%\minimax）。</summary>
    public static string DefaultConfigPath() => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "minimax",
        "config.json");

    /// <summary>次选配置路径：Win-CodexBar 的非 Windows 约定（~/.minimax）按 home 目录映射到 %USERPROFILE%\.minimax。</summary>
    public static string LegacyConfigPath() => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        ".minimax",
        "config.json");

    /// <summary>
    /// 读取凭据（Try 语义，不抛异常）。单个候选路径上：文件缺失/不可读/坏 JSON（含根不是对象）/
    /// api_key 缺失或空白 → 该路径无凭据；首个产出可用 api_key 的路径胜出，均无 → null。
    /// </summary>
    public MinimaxCliCredentials? TryLoad() => TryLoadFrom(_configPath) ?? TryLoadFrom(_legacyConfigPath);

    private static MinimaxCliCredentials? TryLoadFrom(string configPath)
    {
        string contents;
        try
        {
            // 一次性读而不是先探测存在性（TOCTOU 窗口，先例：ZcodeCredentialStore.TryLoad）；
            // FileNotFoundException / DirectoryNotFoundException 均派生自 IOException，一并视作“读不到”。
            contents = File.ReadAllText(configPath);
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

        // api_key 必需（Win-CodexBar read_api_key 的字符串读取；非字符串值按缺失处理）；
        // 空白视为缺失——存 trim 后的值（MinimaxClient 侧本就 trim）。
        if (ReadStringEntry(root, "api_key") is not { } apiKey)
        {
            return null;
        }

        // group_id 可选：仅 legacy billing 路径需要，coding-plan remains 端点用不到（见 MinimaxClient）。
        return new MinimaxCliCredentials(apiKey, ReadStringEntry(root, "group_id"));
    }

    /// <summary>读字符串条目：键缺失/非字符串/空白 → null（空白即缺失，不区分“缺”与“空”）。</summary>
    private static string? ReadStringEntry(JsonObject root, string key) =>
        root[key] is JsonValue value && value.TryGetValue<string>(out var stored)
            ? (string.IsNullOrWhiteSpace(stored) ? null : stored.Trim())
            : null;
}

/// <summary>
/// 从 mcode CLI config.json 读出的登录凭据。仓库惯例为一类型一文件；此处按 ZcodeCredentials 先例
/// 将本记录与其唯一生产者同文件放置（命名空间级、不嵌套）。
/// </summary>
/// <param name="ApiKey">api_key 条目（trim 后明文；TryLoad 产出即保证非空白）。</param>
/// <param name="GroupId">group_id 条目（可选；缺失/空白/非字符串为 null）。</param>
public sealed record MinimaxCliCredentials(string ApiKey, string? GroupId)
{
    /// <summary>
    /// record 合成的 ToString 会打印全部属性（即明文凭据）——覆写为不泄露凭据的安全形式
    /// （先例：ZcodeCredentials.ToString 的同因覆写）。
    /// </summary>
    public override string ToString() =>
        $"MinimaxCliCredentials(ApiKey=set, GroupId={(GroupId is null ? "null" : "set")})";
}
