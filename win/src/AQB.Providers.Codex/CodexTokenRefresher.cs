using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using AQB.Core;

namespace AQB.Providers.Codex;

/// <summary>
/// Refreshes the ChatGPT OAuth refresh token via POST https://auth.openai.com/oauth/token
/// (form-encoded) and merges the response back into auth.json: only tokens.* and last_refresh are
/// replaced, every other key survives, and the write is atomic (temp file + replace).
/// </summary>
public sealed class CodexTokenRefresher
{
    public const string TokenEndpoint = "https://auth.openai.com/oauth/token";
    public const string ClientId = "app_EMoamEEZ73f0CkXaXp7hrann";
    public const string Scope = "openid profile email";

    private static readonly JsonSerializerOptions WriteOptions = new() { WriteIndented = true };

    private readonly HttpClient _http;
    private readonly CodexAuthStore _store;

    public CodexTokenRefresher(HttpMessageHandler? handler = null, string? codexHome = null)
    {
        _http = new HttpClient(handler ?? CodexHttp.CreateDefaultHandler(), disposeHandler: false)
        {
            Timeout = TimeSpan.FromSeconds(30),
        };
        _store = new CodexAuthStore(codexHome);
    }

    /// <summary>
    /// Performs the refresh and the merge write-back; returns the re-read auth info.
    /// Throws <see cref="CodexAuthException"/> (RequiresRelogin = true for 401 / expired-grant
    /// responses, meaning the user must run codex to sign in again).
    /// </summary>
    public async Task<CodexAuthInfo> RefreshAsync(CodexAuthInfo auth, CancellationToken cancellationToken = default)
    {
        var root = ParseObject(auth.RawJson)
            ?? throw new CodexAuthException("Codex auth file is not valid JSON.", requiresRelogin: true);
        var tokens = root["tokens"] as JsonObject ?? new JsonObject();
        root["tokens"] = tokens;

        var refreshToken = CodexAuthStore.PeekToken(auth.RawJson, "refresh_token", "refreshToken");
        if (refreshToken is null)
        {
            throw new CodexAuthException(
                "Codex refresh token is missing — run codex to sign in.",
                requiresRelogin: true);
        }

        using var request = new HttpRequestMessage(HttpMethod.Post, TokenEndpoint);
        request.Content = new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["client_id"] = ClientId,
            ["grant_type"] = "refresh_token",
            ["refresh_token"] = refreshToken,
            ["scope"] = Scope,
        });

        using var response = await _http.SendAsync(request, cancellationToken).ConfigureAwait(false);
        var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            throw new CodexAuthException(
                DescribeFailure(response.StatusCode, body),
                requiresRelogin: response.StatusCode == HttpStatusCode.Unauthorized
                    || BodyIndicatesExpiredRefreshToken(body));
        }

        var payload = ParseObject(body)
            ?? throw new CodexAuthException(
                "Codex token endpoint returned an invalid response.",
                requiresRelogin: true);

        MergeToken(tokens, "access_token", "accessToken", payload["access_token"]);
        MergeToken(tokens, "refresh_token", "refreshToken", payload["refresh_token"]);
        MergeToken(tokens, "id_token", "idToken", payload["id_token"]);
        root["last_refresh"] = DateTimeOffset.UtcNow.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");

        Json.AtomicWrite(_store.AuthFilePath, root.ToJsonString(WriteOptions));

        return _store.Load()
            ?? throw new CodexAuthException("Failed to re-read Codex auth file after token refresh.");
    }

    private static JsonObject? ParseObject(string json)
    {
        try
        {
            return JsonNode.Parse(json) as JsonObject;
        }
        catch (Exception e) when (e is JsonException or ArgumentException)
        {
            return null;
        }
    }

    /// <summary>Replaces the existing token key (snake_case or camelCase, whichever is present); empty/missing response values keep the old token.</summary>
    private static void MergeToken(JsonObject tokens, string snakeKey, string camelKey, JsonNode? incoming)
    {
        if (incoming is not JsonValue value
            || !value.TryGetValue<string>(out var text)
            || string.IsNullOrWhiteSpace(text))
        {
            return;
        }

        if (tokens.ContainsKey(snakeKey))
        {
            tokens[snakeKey] = text;
        }
        else if (tokens.ContainsKey(camelKey))
        {
            tokens[camelKey] = text;
        }
        else
        {
            tokens[snakeKey] = text;
        }
    }

    private static bool BodyIndicatesExpiredRefreshToken(string body) =>
        body.Contains("refresh_token_expired", StringComparison.Ordinal)
        || body.Contains("invalid_grant", StringComparison.Ordinal)
        || body.Contains("refresh_token_invalidated", StringComparison.Ordinal)
        || body.Contains("refresh_token_reused", StringComparison.Ordinal);

    private static string DescribeFailure(HttpStatusCode statusCode, string body) =>
        statusCode == HttpStatusCode.Unauthorized || BodyIndicatesExpiredRefreshToken(body)
            ? "Codex token expired — run codex to refresh"
            : $"Codex token refresh failed (HTTP {(int)statusCode}).";
}
