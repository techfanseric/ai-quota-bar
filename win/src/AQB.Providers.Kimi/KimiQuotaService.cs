using AQB.Core;

namespace AQB.Providers.Kimi;

/// <summary>
/// Kimi quota facade (task A.5). Source order: explicit API key (web API, key as Bearer)
/// → desktop token-store session → kimi CLI /status runner (can be disabled). Each stage
/// that is available is attempted; on failure the next source is tried, mirroring the
/// simplified Windows fallback chain (the macOS account-stickiness rules do not apply here).
/// After a successful web fetch, the optional GetSubscriptionStats call fills
/// SubscribeTitle / SubscribeEndTimeText (failures ignored).
/// </summary>
public sealed class KimiQuotaService
{
    private readonly string? _apiKey;
    private readonly KimiDesktopSessionReader _desktopReader;
    private readonly KimiCliRunner? _cliRunner;
    private readonly HttpMessageHandler? _handler;

    public KimiQuotaService(
        string? apiKey = null,
        KimiDesktopSessionReader? desktopReader = null,
        KimiCliRunner? cliRunner = null,
        HttpMessageHandler? handler = null,
        bool cliEnabled = true)
    {
        _apiKey = apiKey;
        _desktopReader = desktopReader ?? new KimiDesktopSessionReader();
        _cliRunner = cliRunner ?? (cliEnabled ? new KimiCliRunner() : null);
        _handler = handler;
    }

    public async Task<ProviderSnapshot> FetchAsync(CancellationToken cancellationToken = default)
    {
        var errors = new List<string>();

        if (!string.IsNullOrWhiteSpace(_apiKey))
        {
            try
            {
                return await FetchWebSnapshotAsync(KimiWebCredential.ForApiKey(_apiKey.Trim()), "Kimi Code API", cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception e)
            {
                errors.Add(e.Message);
            }
        }

        KimiWebCredential? desktopCredential = null;
        try
        {
            desktopCredential = _desktopReader.TryLoad();
        }
        catch
        {
            // Reader is best-effort by contract; treat as unavailable.
        }

        if (desktopCredential is not null)
        {
            var usable = true;
            try
            {
                desktopCredential.ValidateWebSession();
            }
            catch (KimiSessionException e)
            {
                usable = false;
                errors.Add(e.Message);
            }

            if (usable)
            {
                try
                {
                    return await FetchWebSnapshotAsync(desktopCredential, "Kimi Desktop", cancellationToken)
                        .ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    throw;
                }
                catch (Exception e)
                {
                    errors.Add(e.Message);
                }
            }
        }

        if (_cliRunner is not null)
        {
            try
            {
                var cliSnapshot = await _cliRunner.RunStatusAsync(cancellationToken).ConfigureAwait(false);
                return cliSnapshot.ToProviderSnapshot();
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception e)
            {
                errors.Add(e.Message);
            }
        }

        return new ProviderSnapshot
        {
            Kind = ProviderKind.Kimi,
            Status = ProviderStatus.Failed,
            Error = errors.Count > 0
                ? string.Join(" | ", errors)
                : "Kimi 未配置:缺少 API key、桌面登录或 CLI / Kimi is not configured: no API key, desktop session, or CLI.",
        };
    }

    private async Task<ProviderSnapshot> FetchWebSnapshotAsync(
        KimiWebCredential credential,
        string sourceLabel,
        CancellationToken cancellationToken)
    {
        using var client = new KimiWebUsageClient(_handler);
        var result = await client.FetchAsync(credential, cancellationToken).ConfigureAwait(false);

        return new ProviderSnapshot
        {
            Kind = ProviderKind.Kimi,
            Status = ProviderStatus.Ok,
            LastUpdatedUtc = result.CapturedAtUtc,
            Accounts = new[]
            {
                new ProviderAccountSnapshot
                {
                    AccountKey = AccountFingerprint.WatchEmail(credential.Token),
                    Label = credential.AccountLabel(),
                    SourceLabel = sourceLabel,
                    IsCurrent = true,
                    Windows = result.Windows,
                },
            },
            SubscribeTitle = result.SubscribeTitle,
            SubscribeEndTimeText = KimiText.EndTimeText(result.SubscribeEndUtc),
            DetailText = sourceLabel + " · " + credential.Origin,
        };
    }
}
