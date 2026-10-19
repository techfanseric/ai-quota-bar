using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AQB.Providers.Codex;

/// <summary>Read-only app-server probe; no threads or model turns are created.</summary>
public sealed class CodexCliUsageClient
{
    private readonly string _home;
    private readonly Func<string?> _locate;
    private readonly TimeSpan _timeout;

    public CodexCliUsageClient(string? codexHome = null, Func<string?>? locate = null, TimeSpan? timeout = null)
    {
        _home = CodexPaths.ResolveHome(codexHome);
        _locate = locate ?? FindExecutable;
        _timeout = timeout ?? TimeSpan.FromSeconds(20);
    }

    public static string? FindExecutable()
    {
        var dirs = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator)
            .Append(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm"));
        var target = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture == System.Runtime.InteropServices.Architecture.Arm64
            ? "aarch64-pc-windows-msvc" : "x86_64-pc-windows-msvc";
        var package = target.StartsWith("aarch64") ? "codex-win32-arm64" : "codex-win32-x64";
        foreach (var entry in dirs)
        {
            var dir = entry.Trim().Trim('"');
            if (dir.Length == 0 || !Path.IsPathFullyQualified(dir)) continue;
            // Prefer native binaries, including npm's platform package, without a cmd.exe shell.
            foreach (var candidate in new[]
            {
                Path.Combine(dir, "codex.exe"),
                Path.Combine(dir, "node_modules", "@openai", "codex", "node_modules", "@openai", package, "vendor", target, "bin", "codex.exe"),
                Path.Combine(dir, "node_modules", "@openai", "codex", "vendor", target, "codex", "codex.exe"),
            })
            {
                if (File.Exists(candidate)) return candidate;
            }
        }
        return null;
    }

    public async Task<CodexUsageResult> FetchAsync(CodexAuthInfo auth, CancellationToken cancellationToken = default)
    {
        var executable = _locate() ?? throw new CodexException("Codex CLI executable not found (PATH or npm installation).");
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = Path.GetTempPath(),
        };
        start.ArgumentList.Add("app-server");
        start.Environment["CODEX_HOME"] = _home;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(_timeout);
        using var process = new Process { StartInfo = start };
        if (!process.Start()) throw new CodexException("Could not start Codex CLI.");
        // Drain stderr without retaining auth diagnostics or unbounded buffers.
        var drain = DrainAsync(process.StandardError, timeout.Token);
        try
        {
            await process.StandardInput.WriteLineAsync("""{"id":1,"method":"initialize","params":{"clientInfo":{"name":"ai_quota_bar","title":"AI Quota Bar","version":"1.38.2"}}}""".AsMemory(), timeout.Token);
            await process.StandardInput.FlushAsync(timeout.Token);
            await ReadReplyAsync(process.StandardOutput, 1, timeout.Token);
            await process.StandardInput.WriteLineAsync("""{"method":"initialized"}""".AsMemory(), timeout.Token);
            await process.StandardInput.WriteLineAsync("""{"id":2,"method":"account/rateLimits/read"}""".AsMemory(), timeout.Token);
            await process.StandardInput.FlushAsync(timeout.Token);
            return ParseResponse(auth, await ReadReplyAsync(process.StandardOutput, 2, timeout.Token));
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new CodexException("Codex CLI quota query timed out.");
        }
        finally
        {
            if (!process.HasExited)
            {
                try { process.Kill(entireProcessTree: true); }
                catch (InvalidOperationException) { }
            }
            timeout.Cancel();
            try { await drain; }
            catch (OperationCanceledException) { }
            catch (IOException) { }
        }
    }

    private static async Task DrainAsync(StreamReader reader, CancellationToken token)
    {
        var buffer = new char[1024];
        while (await reader.ReadAsync(buffer.AsMemory(), token) > 0) { }
    }

    private static async Task<JsonObject> ReadReplyAsync(StreamReader reader, int id, CancellationToken token)
    {
        while (await reader.ReadLineAsync(token) is { } line)
        {
            JsonObject? message;
            try { message = JsonNode.Parse(line) as JsonObject; }
            catch (JsonException) { continue; }
            if (message?["id"] is not JsonValue value || !value.TryGetValue<int>(out var replyId) || replyId != id) continue;
            if (message["error"] is not null) throw new CodexException($"Codex CLI request failed (RPC {message["error"]?["code"]}).");
            return message["result"] as JsonObject ?? throw new CodexException("Codex CLI returned an invalid response.");
        }
        throw new CodexException("Codex CLI exited before returning quota data.");
    }

    public static CodexUsageResult ParseResponse(CodexAuthInfo auth, JsonObject response)
    {
        try { return ParseLimits(auth, response); }
        catch (Exception error) when (error is InvalidOperationException or FormatException or ArgumentOutOfRangeException or OverflowException)
        {
            throw new CodexException("Codex CLI returned malformed quota windows.");
        }
    }

    private static CodexUsageResult ParseLimits(CodexAuthInfo auth, JsonObject response)
    {
        var limit = response["rateLimitsByLimitId"]?["codex"] as JsonObject
            ?? response["rateLimits"] as JsonObject
            ?? throw new CodexException("Codex CLI returned no rate limits.");
        JsonNode? MapWindow(JsonNode? node) => node is not JsonObject window ? null : new JsonObject
        {
            ["used_percent"] = window["usedPercent"]?.DeepClone(),
            ["reset_at"] = window["resetsAt"]?.DeepClone(),
            ["limit_window_seconds"] = (window["windowDurationMins"]?.GetValue<long>() ?? 0) * 60,
        };
        var mapped = new JsonObject
        {
            ["plan_type"] = limit["planType"]?.DeepClone(),
            ["rate_limit"] = new JsonObject
            {
                ["primary_window"] = MapWindow(limit["primary"]),
                ["secondary_window"] = MapWindow(limit["secondary"]),
            },
        };
        var parsed = CodexUsageClient.Parse(auth, mapped.ToJsonString());
        if (parsed.Windows.Count == 0) throw new CodexException("Codex CLI returned no quota windows.");
        return new CodexUsageResult
        {
            Auth = auth, Windows = parsed.Windows, PlanTitle = parsed.PlanTitle,
            AccountId = auth.AccountId, CapturedAtUtc = parsed.CapturedAtUtc, SourceLabel = "Codex CLI",
        };
    }
}
