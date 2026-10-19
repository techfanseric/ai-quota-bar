using AQB.Core;

namespace AQB.Providers.Codex;

/// <summary>
/// Facade over auth read + usage fetch (with 401 refresh retry) producing a ProviderSnapshot.
/// If the Codex account is switched while a fetch is in flight (auth.json before/after account_id
/// mismatch), the result is discarded and the whole fetch retried exactly once.
/// </summary>
public sealed class CodexQuotaService
{
    public const string NoCredentialsError = "No Codex credentials";
    public const string AccountChangedError = "Codex account changed during fetch";

    private const int MaxFetchAttempts = 2;

    private readonly CodexAuthStore _authStore;
    private readonly CodexUsageClient _usageClient;
    private readonly Func<CodexAuthInfo, CancellationToken, Task<CodexUsageResult>>? _cliFetch;
    private ProviderSnapshot? _lastSuccess;

    public CodexQuotaService(HttpMessageHandler? handler = null, string? codexHome = null,
        Func<CodexAuthInfo, CancellationToken, Task<CodexUsageResult>>? cliFetch = null)
    {
        _authStore = new CodexAuthStore(codexHome);
        _usageClient = new CodexUsageClient(handler, codexHome);
        _cliFetch = cliFetch;
    }

    public async Task<ProviderSnapshot> FetchAsync(CancellationToken cancellationToken = default)
    {
        var before = _authStore.Load();
        if (before is null)
        {
            return Snapshot(ProviderStatus.Offline, NoCredentialsError);
        }

        for (var attempt = 1; ; attempt++)
        {
            CodexUsageResult result;
            try
            {
                result = await FetchWithFallbackAsync(before, cancellationToken).ConfigureAwait(false);
            }
            catch (CodexAuthException e)
            {
                return Snapshot(ProviderStatus.Offline, e.Message);
            }
            catch (CodexException e)
            {
                return Snapshot(ProviderStatus.Failed, e.Message);
            }
            catch (HttpRequestException e)
            {
                return Snapshot(ProviderStatus.Failed, $"Codex usage request failed: {CodexHttp.DescribeFailure(e)}");
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (TaskCanceledException)
            {
                return Snapshot(ProviderStatus.Failed, "Codex usage request timed out.");
            }

            // Account stability check: the fetch may have taken a while and auth.json may have
            // been switched to another account meanwhile — such results must not be booked.
            var after = _authStore.Load();
            if (after is null)
            {
                return Snapshot(ProviderStatus.Offline, NoCredentialsError);
            }

            if (after.AccountId != before.AccountId)
            {
                if (attempt < MaxFetchAttempts)
                {
                    before = after;
                    continue;
                }

                return Snapshot(ProviderStatus.Failed, AccountChangedError);
            }

            var account = new ProviderAccountSnapshot
            {
                AccountKey = AccountFingerprint.Codex(after.AccountId),
                Label = after.Email ?? "",
                IsCurrent = true,
                SourceLabel = after.HasApiKey ? "API key" : result.SourceLabel,
                Windows = result.Windows,
                PlanTitle = result.PlanTitle,
            };

            _lastSuccess = new ProviderSnapshot
            {
                Kind = ProviderKind.Codex,
                Status = ProviderStatus.Ok,
                LastUpdatedUtc = result.CapturedAtUtc,
                Accounts = new[] { account },
            };
            return _lastSuccess;
        }
    }

    private async Task<CodexUsageResult> FetchWithFallbackAsync(CodexAuthInfo auth, CancellationToken cancellationToken)
    {
        try
        {
            return await _usageClient.FetchAsync(auth, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error) when (_cliFetch is not null && !auth.HasApiKey
            && !cancellationToken.IsCancellationRequested
            && error is HttpRequestException or CodexException or TaskCanceledException)
        {
            try
            {
                return await _cliFetch(auth, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
            catch (Exception cliError) when (cliError is CodexException or HttpRequestException or IOException or System.ComponentModel.Win32Exception or OperationCanceledException)
            {
                var detail = error is HttpRequestException http ? CodexHttp.DescribeFailure(http) : error.Message;
                throw new CodexException($"OAuth: {detail}; CLI: {cliError.Message}");
            }
        }
    }

    private ProviderSnapshot Snapshot(ProviderStatus status, string error)
    {
        // Keep stale data only for the same signed-in account; never resurrect another account.
        var current = _authStore.Load();
        var previous = status == ProviderStatus.Failed && current is not null
            && _lastSuccess?.Accounts.FirstOrDefault()?.AccountKey == AccountFingerprint.Codex(current.AccountId)
            ? _lastSuccess : null;
        return new ProviderSnapshot
        {
            Kind = ProviderKind.Codex,
            Status = status,
            Error = error,
            Accounts = previous?.Accounts ?? Array.Empty<ProviderAccountSnapshot>(),
            LastUpdatedUtc = previous?.LastUpdatedUtc,
        };
    }
}
