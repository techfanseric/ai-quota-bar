// Swift 来源：.dependencies/codexbar/Tests/CodexBarTests/CodexOAuthTests.swift（parses O auth credentials /
//   parses legacy camel case O auth credentials / parses API key credentials / OAuth parse ignores a
//   PAT-only auth file / blank personal access token is missing）与 CodexPATTests.swift
//   （parses personal access token credentials / PAT parse does not fall through to OAuth tokens）
//   + 本地文件加载/保存（Swift reset-credit token load 与 save 的文件语义）。
// fixtures：auth-json-oauth.json、auth-json-pat.json（fixture 派生变换覆盖 camelCase/空白/混合形态）。

#nullable enable

using System;
using System.IO;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using AIQuotaBar.Providers.Codex.Credentials;
using Xunit;

namespace AIQuotaBar.Providers.Tests.Codex;

public sealed class CodexAuthStoreTests
{
    // ------------------------------------------------------------------
    // 解析（fixtures 直读）。
    // ------------------------------------------------------------------

    [Fact]
    public void ParsesOAuthCredentials()
    {
        var credentials = CodexAuthStore.Parse(CodexFixtures.Read("auth-json-oauth.json"));

        Assert.Equal("access-token", credentials.AccessToken);
        Assert.Equal("refresh-token", credentials.RefreshToken);
        Assert.Equal("id-token", credentials.IdToken);
        Assert.Equal("account-123", credentials.AccountId);
        Assert.NotNull(credentials.LastRefresh);
        Assert.Equal(
            new DateTimeOffset(2025, 12, 20, 12, 34, 56, TimeSpan.Zero),
            credentials.LastRefresh);
        Assert.False(credentials.IsApiKey);
    }

    [Fact]
    public void ParsesLegacyCamelCaseOAuthCredentials()
    {
        // Swift: parses legacy camel case O auth credentials —— tokens 键的 camelCase 变体。
        var json = CodexFixtures.Transform("auth-json-oauth.json", root =>
        {
            var tokens = (JsonObject)root["tokens"]!;
            root["tokens"] = new JsonObject
            {
                ["accessToken"] = (string?)tokens["access_token"],
                ["refreshToken"] = (string?)tokens["refresh_token"],
                ["idToken"] = (string?)tokens["id_token"],
                ["accountId"] = (string?)tokens["account_id"],
            };
        });

        var credentials = CodexAuthStore.Parse(json);

        Assert.Equal("access-token", credentials.AccessToken);
        Assert.Equal("refresh-token", credentials.RefreshToken);
        Assert.Equal("id-token", credentials.IdToken);
        Assert.Equal("account-123", credentials.AccountId);
        Assert.NotNull(credentials.LastRefresh);
    }

    [Fact]
    public void ParsesApiKeyCredentials()
    {
        // Swift: parses API key credentials —— OPENAI_API_KEY 非空时优先于 tokens。
        var json = CodexFixtures.Transform("auth-json-oauth.json", root =>
        {
            root["OPENAI_API_KEY"] = "sk-test";
        });

        var credentials = CodexAuthStore.Parse(json);

        Assert.Equal("sk-test", credentials.AccessToken);
        Assert.Equal(string.Empty, credentials.RefreshToken);
        Assert.Null(credentials.IdToken);
        Assert.Null(credentials.AccountId);
        Assert.True(credentials.IsApiKey);
        Assert.False(credentials.NeedsRefresh);
    }

    [Fact]
    public void OAuthParseIgnoresPatOnlyFile()
    {
        // Swift: OAuth parse ignores a PAT-only auth file —— 纯 PAT 文件按 OAuth 解析必须报
        // missingTokens，不得把 PAT 当成 OAuth 凭据。
        var exception = Assert.Throws<CodexCredentialException>(() =>
            CodexAuthStore.Parse(CodexFixtures.Read("auth-json-pat.json")));

        Assert.Equal(CodexCredentialError.MissingTokens, exception.Error);
    }

    [Fact]
    public void ParsesPersonalAccessTokenCredentials()
    {
        var credentials = CodexAuthStore.ParsePat(CodexFixtures.Read("auth-json-pat.json"));

        Assert.Equal("at-test-token", credentials.Token);
        Assert.Equal(CodexCredentialSource.CodexHome, credentials.Source);
    }

    [Fact]
    public void BlankPersonalAccessTokenIsMissing()
    {
        // Swift: blank personal access token is missing —— 空白 PAT 视为缺失。
        var json = CodexFixtures.Transform("auth-json-pat.json", root =>
        {
            root["personal_access_token"] = "  ";
        });

        var exception = Assert.Throws<CodexCredentialException>(() => CodexAuthStore.ParsePat(json));

        Assert.Equal(CodexCredentialError.MissingTokens, exception.Error);
    }

    [Fact]
    public void PatParseDoesNotFallThroughToOAuthTokens()
    {
        // Swift: PAT parse does not fall through to OAuth tokens —— 同一文件同时含 PAT、
        // API key 与 tokens 时：PAT 解析取 PAT；OAuth 解析取 API key（优先级高于 tokens）。
        var json = CodexFixtures.Transform("auth-json-oauth.json", root =>
        {
            root["personal_access_token"] = "at-preferred";
            root["OPENAI_API_KEY"] = "sk-test";
        });

        var pat = CodexAuthStore.ParsePat(json);
        var oauth = CodexAuthStore.Parse(json);

        Assert.Equal("at-preferred", pat.Token);
        Assert.Equal("sk-test", oauth.AccessToken);
        Assert.True(oauth.IsApiKey);
    }

    [Fact]
    public void ParseOAuthTokensIgnoresApiKeyBesideTokens()
    {
        // Swift: reset-credit token load ignores an API key beside O auth tokens ——
        // tokens 优先入口不受同文件 OPENAI_API_KEY 影响。
        var json = CodexFixtures.Transform("auth-json-oauth.json", root =>
        {
            root["OPENAI_API_KEY"] = "sk-test";
        });

        var credentials = CodexAuthStore.ParseOAuthTokens(json);

        Assert.Equal("access-token", credentials.AccessToken);
        Assert.Equal("account-123", credentials.AccountId);
        Assert.False(credentials.IsApiKey);
    }

    [Fact]
    public void ParseRejectsInvalidJson()
    {
        var exception = Assert.Throws<CodexCredentialException>(() => CodexAuthStore.Parse("not json"));

        Assert.Equal(CodexCredentialError.DecodeFailed, exception.Error);
    }

    // ------------------------------------------------------------------
    // 文件加载（CODEX_HOME 覆盖 + 临时目录）。
    // ------------------------------------------------------------------

    [Fact]
    public async Task LoadOAuthAsyncReadsAuthJsonFromConfiguredCodexHome()
    {
        using var home = TempCodexHome.WithAuthJson("auth-json-oauth.json");
        var store = new CodexAuthStore(home);

        var credentials = await store.LoadOAuthAsync();

        Assert.Equal("access-token", credentials.AccessToken);
        Assert.Equal(Path.Combine(home.CodexHomeDirectory, "auth.json"), store.AuthFilePath);
    }

    [Fact]
    public async Task LoadPatAsyncReadsAuthJsonFromConfiguredCodexHome()
    {
        using var home = TempCodexHome.WithAuthJson("auth-json-pat.json");
        var store = new CodexAuthStore(home);

        var credentials = await store.LoadPatAsync();

        Assert.Equal("at-test-token", credentials.Token);
    }

    [Fact]
    public async Task LoadOAuthAsyncThrowsNotFoundWhenAuthJsonMissing()
    {
        using var home = new TempCodexHome();
        var store = new CodexAuthStore(home);

        var exception = await Assert.ThrowsAsync<CodexCredentialException>(() => store.LoadOAuthAsync());

        Assert.Equal(CodexCredentialError.NotFound, exception.Error);
    }

    [Fact]
    public async Task SaveAsyncMergesTokensIntoExistingFile()
    {
        using var home = TempCodexHome.WithAuthJson("auth-json-oauth.json");
        var store = new CodexAuthStore(home);
        var original = await store.LoadOAuthAsync();
        var refreshedAt = new DateTimeOffset(2026, 9, 24, 8, 0, 0, TimeSpan.Zero);

        await store.SaveAsync(original with
        {
            AccessToken = "rotated-access",
            RefreshToken = "rotated-refresh",
            LastRefresh = refreshedAt,
        });

        var reloaded = await store.LoadOAuthAsync();
        Assert.Equal("rotated-access", reloaded.AccessToken);
        Assert.Equal("rotated-refresh", reloaded.RefreshToken);
        Assert.Equal("id-token", reloaded.IdToken);
        Assert.Equal("account-123", reloaded.AccountId);
        Assert.Equal(refreshedAt, reloaded.LastRefresh);

        // 合并语义：文件中其余键（OPENAI_API_KEY 等）保留（Swift: save 先读旧文件再覆盖 tokens）。
        var saved = JsonNode.Parse(File.ReadAllText(store.AuthFilePath)) as JsonObject;
        Assert.NotNull(saved);
        Assert.True(saved!.ContainsKey("OPENAI_API_KEY"));
        Assert.Equal("rotated-access", (string?)saved["tokens"]!["access_token"]);
        Assert.Equal(
            "2026-09-24T08:00:00Z",
            (string?)saved["last_refresh"]);
    }

    /// <summary>临时 CODEX_HOME（Path.GetTempPath + UUID 子目录；IDisposable 清理，对应 Swift setUp/tearDown）。</summary>
    private sealed class TempCodexHome : ICodexEnvironment, IDisposable
    {
        public string CodexHomeDirectory { get; }

        private TempCodexHome(string directory)
        {
            CodexHomeDirectory = directory;
            Directory.CreateDirectory(directory);
        }

        public static TempCodexHome WithAuthJson(string fixtureName)
        {
            var home = new TempCodexHome(
                Path.Combine(Path.GetTempPath(), "aiquotabar-codex-tests-" + Guid.NewGuid().ToString("N")));
            File.WriteAllText(
                Path.Combine(home.CodexHomeDirectory, "auth.json"),
                CodexFixtures.Read(fixtureName));
            return home;
        }

        public void Dispose()
        {
            try
            {
                Directory.Delete(CodexHomeDirectory, recursive: true);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // 清理失败不影响测试结果。
            }
        }
    }
}
