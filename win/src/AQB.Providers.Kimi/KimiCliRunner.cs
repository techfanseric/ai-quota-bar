using System.ComponentModel;
using System.Diagnostics;
using System.Text;

namespace AQB.Providers.Kimi;

/// <summary>Locates the official `kimi` CLI executable (spec §1.5): $KIMI_CODE_HOME/bin/kimi, then PATH.</summary>
public static class KimiCliLocator
{
    private static readonly string[] ExecutableNames = { "kimi", "kimi.cmd", "kimi.exe" };

    public static string? Locate(Func<string, string?>? getEnvironmentVariable = null)
    {
        var env = getEnvironmentVariable ?? Environment.GetEnvironmentVariable;
        return LocateWithEnv(env);
    }

    /// <summary>Parameterless entry point used as the runner's default locator.</summary>
    public static string? FindExecutable() => LocateWithEnv(Environment.GetEnvironmentVariable);

    private static string? LocateWithEnv(Func<string, string?> env)
    {
        var home = env("KIMI_CODE_HOME");
        if (!string.IsNullOrWhiteSpace(home))
        {
            foreach (var candidate in ExecutableNames.Select(name => Path.Combine(home, "bin", name)))
            {
                if (File.Exists(candidate))
                {
                    return candidate;
                }
            }
        }

        var path = env("PATH");
        if (string.IsNullOrWhiteSpace(path))
        {
            return null;
        }

        foreach (var rawDir in path.Split(Path.PathSeparator))
        {
            var dir = rawDir.Trim().Trim('"');
            if (dir.Length == 0)
            {
                continue;
            }

            foreach (var name in ExecutableNames)
            {
                var candidate = Path.Combine(dir, name);
                if (File.Exists(candidate))
                {
                    return candidate;
                }
            }
        }

        return null;
    }
}

/// <summary>
/// Runs `kimi` CLI /status and parses the quota output (spec §1.5, task A.3).
///
/// Differences from the macOS PTY probe, by design: Windows has no PTY here, so the CLI is
/// launched with redirected stdin/stdout/stderr pipes and a hidden window (CreateNoWindow).
/// The macOS probe reacted to "Trust this folder?" with ESC[A+Enter inside the PTY; with
/// pipes we cannot answer interactive prompts, so the parser surfaces that case as
/// workspaceTrustRequired instead. "/status\r\n" is written to stdin once the "context:"
/// prompt appears in the output, or 1.5s after launch at the latest (simplified trigger,
/// task A.3). The process is killed after the 10s total timeout.
/// </summary>
public sealed class KimiCliRunner
{
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan SendDelay = TimeSpan.FromSeconds(1.5);

    private readonly TimeSpan _timeout;
    private readonly Func<string?> _locateExecutable;

    public KimiCliRunner(TimeSpan? timeout = null, Func<string?>? locateExecutable = null)
    {
        _timeout = timeout ?? DefaultTimeout;
        _locateExecutable = locateExecutable ?? KimiCliLocator.FindExecutable;    }

    public async Task<KimiUsageSnapshot> RunStatusAsync(CancellationToken cancellationToken = default)
    {
        var output = await CaptureStatusOutputAsync(cancellationToken).ConfigureAwait(false);
        return KimiCliStatusParser.Parse(output, DateTimeOffset.Now);
    }

    /// <summary>Runs the CLI and returns the combined stdout+stderr text (before parsing).</summary>
    public async Task<string> CaptureStatusOutputAsync(CancellationToken cancellationToken = default)
    {
        var executable = _locateExecutable();
        if (executable is null)
        {
            throw new KimiCliException(
                KimiCliReason.CliNotInstalled,
                "未找到 kimi CLI / The kimi CLI executable was not found.");
        }

        var probeDirectory = Path.Combine(Path.GetTempPath(), "AQB.KimiStatusProbe");
        Directory.CreateDirectory(probeDirectory);

        var startInfo = new ProcessStartInfo
        {
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = probeDirectory,
        };
        if (executable.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase) ||
            executable.EndsWith(".bat", StringComparison.OrdinalIgnoreCase))
        {
            // .cmd/.bat launchers must go through cmd.exe on .NET Core.
            startInfo.FileName = "cmd.exe";
            startInfo.Arguments = "/c \"" + executable + "\"";
        }
        else
        {
            startInfo.FileName = executable;
        }

        using var process = new Process { StartInfo = startInfo };
        if (!process.Start())
        {
            throw new KimiCliException(
                KimiCliReason.StatusUnavailable,
                "kimi CLI 启动失败 / Failed to start the kimi CLI.");
        }

        var stdout = new StringBuilder();
        var stderr = new StringBuilder();
        var statusSent = false;

        void SendStatus()
        {
            if (statusSent)
            {
                return;
            }

            statusSent = true;
            try
            {
                process.StandardInput.Write("/status\r\n");
                process.StandardInput.Flush();
            }
            catch (IOException)
            {
            }
            catch (ObjectDisposedException)
            {
            }
        }

        var stdoutTask = Task.Run(async () =>
        {
            var buffer = new char[512].AsMemory();
            while (true)
            {
                int read;
                try
                {
                    read = await process.StandardOutput.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                catch (IOException)
                {
                    break;
                }

                if (read <= 0)
                {
                    break;
                }

                stdout.Append(buffer.Span);
                if (!statusSent && stdout.ToString().Contains("context:", StringComparison.Ordinal))
                {
                    SendStatus();
                }
            }
        }, CancellationToken.None);

        var stderrTask = Task.Run(async () =>
        {
            var buffer = new char[512].AsMemory();
            while (true)
            {
                int read;
                try
                {
                    read = await process.StandardError.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                catch (IOException)
                {
                    break;
                }

                if (read <= 0)
                {
                    break;
                }

                stderr.Append(buffer.Span);
            }
        }, CancellationToken.None);

        // Simplified trigger: also send /status after a fixed 1.5s even without a "context:" prompt.
        var fallbackSendTask = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(SendDelay, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }

            SendStatus();
        }, CancellationToken.None);

        try
        {
            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeoutCts.CancelAfter(_timeout);
            try
            {
                await process.WaitForExitAsync(timeoutCts.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                TryKill(process);
                throw new KimiCliException(
                    KimiCliReason.Timeout,
                    "kimi CLI 超时 / The kimi CLI status probe timed out.");
            }
        }
        finally
        {
            TryCloseStandardInput(process);
        }

        try
        {
            await Task.WhenAll(stdoutTask, stderrTask, fallbackSendTask).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (IOException)
        {
        }

        return stdout.ToString() + "\n" + stderr;
    }

    private static void TryCloseStandardInput(Process process)
    {
        try
        {
            process.StandardInput.Close();
        }
        catch (IOException)
        {
        }
        catch (ObjectDisposedException)
        {
        }
    }

    private static void TryKill(Process process)
    {
        try
        {
            process.Kill(entireProcessTree: true);
        }
        catch (InvalidOperationException)
        {
        }
        catch (Win32Exception)
        {
        }
    }
}
