using AQB.Core;

namespace AQB.App;

/// <summary>Left-click control center: quota cards per provider, tasks, route, connections.</summary>
internal sealed class ControlCenterForm : Form
{
    private readonly QuotaOrchestrator _orchestrator;
    private readonly Action _openSettings;
    private readonly Action _openClash;
    private readonly Action _openConnections;
    private readonly Func<(string? group, string? selected, int? delayMs)> _routeInfo;
    private readonly Func<(int count, double up, double down)> _connectionInfo;
    private readonly Func<(string status, int tasks, string providers)> _protectionInfo;
    private readonly Func<IReadOnlyList<WatchedRowView>> _watchedRows;
    private readonly Func<AppUpdateBannerView?> _updateInfo;
    private readonly FlowLayoutPanel _flow = new();

    public ControlCenterForm(
        QuotaOrchestrator orchestrator,
        Action openSettings,
        Action openClash,
        Action openConnections,
        Func<(string?, string?, int?)> routeInfo,
        Func<(int, double, double)> connectionInfo,
        Func<(string, int, string)> protectionInfo,
        Func<IReadOnlyList<WatchedRowView>>? watchedRows = null,
        Func<AppUpdateBannerView?>? updateInfo = null)
    {
        _orchestrator = orchestrator;
        _openSettings = openSettings;
        _openClash = openClash;
        _openConnections = openConnections;
        _routeInfo = routeInfo;
        _connectionInfo = connectionInfo;
        _protectionInfo = protectionInfo;
        _watchedRows = watchedRows ?? (() => Array.Empty<WatchedRowView>());
        _updateInfo = updateInfo ?? (() => null);

        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        AutoScaleMode = AutoScaleMode.Dpi;
        BackColor = Color.FromArgb(32, 32, 36);
        Size = new Size(340, 60);
        Font = new Font("Segoe UI", 9f);

        _flow.Dock = DockStyle.Fill;
        _flow.FlowDirection = FlowDirection.TopDown;
        _flow.WrapContents = false;
        _flow.AutoScroll = true;
        _flow.Padding = new Padding(10);
        Controls.Add(_flow);

        _orchestrator.SnapshotsChanged += OnSnapshotsChanged;
        // Watched rows and the update banner change independently of quota snapshots.
        _refreshTimer.Tick += (_, _) => Rebuild();
        _refreshTimer.Start();
        Rebuild();
    }

    private readonly System.Windows.Forms.Timer _refreshTimer = new() { Interval = 30_000 };

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        PositionNearTray();
    }

    protected override void OnDeactivate(EventArgs e)
    {
        base.OnDeactivate(e);
        Close();
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (keyData == Keys.Escape)
        {
            Close();
            return true;
        }

        return base.ProcessCmdKey(ref msg, keyData);
    }

    private void OnSnapshotsChanged() =>
        BeginInvoke(() => Rebuild());

    private void Rebuild()
    {
        if (IsDisposed)
        {
            return;
        }

        _flow.SuspendLayout();
        _flow.Controls.Clear();

        var snapshots = _orchestrator.Latest;
        var height = 8;

        foreach (var kind in OrderedKinds())
        {
            var snapshot = snapshots.GetValueOrDefault(kind);
            var card = BuildProviderCard(kind, snapshot);
            _flow.Controls.Add(card);
            height += card.Height + 6;
        }

        var (status, tasks, providers) = _protectionInfo();
        var (group, selected, delayMs) = _routeInfo();
        var (openAi, upBps, downBps) = _connectionInfo();

        var statusCard = new Panel
        {
            Width = _flow.ClientSize.Width - _flow.Padding.Horizontal - 8,
            Height = tasks > 0 || !string.IsNullOrEmpty(group) ? 64 : 30,
            BackColor = Color.FromArgb(42, 42, 47),
        };
        if (tasks > 0)
        {
            statusCard.Controls.Add(new Label
            {
                Text = $"Active tasks: {tasks} ({providers}) · sleep protection: {status}",
                ForeColor = Color.FromArgb(120, 200, 150),
                Dock = DockStyle.Top,
                Height = 20,
                TextAlign = ContentAlignment.MiddleLeft,
                Padding = new Padding(8, 0, 0, 0),
            });
        }

        if (!string.IsNullOrEmpty(group))
        {
            var routeLabel = new Label
            {
                Text = $"Route · {group}: {selected ?? "-"}{(delayMs is > 0 ? $" ({delayMs}ms)" : "")}",
                ForeColor = Color.Gainsboro,
                Dock = DockStyle.Top,
                Height = 20,
                TextAlign = ContentAlignment.MiddleLeft,
                Padding = new Padding(8, 0, 0, 0),
                Cursor = Cursors.Hand,
            };
            routeLabel.Click += (_, _) => { _openClash(); Close(); };
            statusCard.Controls.Add(routeLabel);
            statusCard.Controls.Add(new Label
            {
                Text = $"OpenAI connections: {openAi} · ↓{FormatBps(downBps)} ↑{FormatBps(upBps)}",
                ForeColor = Color.Gray,
                Dock = DockStyle.Top,
                Height = 20,
                TextAlign = ContentAlignment.MiddleLeft,
                Padding = new Padding(8, 0, 0, 0),
                Cursor = Cursors.Hand,
            });
        }
        else
        {
            statusCard.Controls.Add(new Label
            {
                Text = "Clash controller not found · connections panel",
                ForeColor = Color.Gray,
                Dock = DockStyle.Top,
                Height = 20,
                TextAlign = ContentAlignment.MiddleLeft,
                Padding = new Padding(8, 0, 0, 0),
                Cursor = Cursors.Hand,
            });
        }
        statusCard.Controls[^1].Click += (_, _) => { _openConnections(); Close(); };

        _flow.Controls.Add(statusCard);
        height += statusCard.Height + 6;

        var watchedRows = _watchedRows();
        if (watchedRows.Count > 0)
        {
            var watchedCard = new Panel
            {
                Width = statusCard.Width,
                Height = 30 + 22 * watchedRows.Count,
                BackColor = Color.FromArgb(42, 42, 47),
            };
            watchedCard.Controls.Add(new Label
            {
                Text = "Watched accounts",
                ForeColor = Color.Gainsboro,
                Font = new Font("Segoe UI Semibold", 9.5f),
                Dock = DockStyle.Top,
                Height = 22,
                TextAlign = ContentAlignment.MiddleLeft,
                Padding = new Padding(8, 4, 0, 0),
            });
            foreach (var row in watchedRows)
            {
                var detail = row.StatusText == "available" && row.RemainingPercent is { } remaining
                    ? $"{remaining:0}% left · {row.WindowName ?? ""} · {row.ResetsAtText ?? ""}"
                    : row.StatusText;
                var color = row.StatusText switch
                {
                    "available" => Color.FromArgb(110, 200, 140),
                    "stale" => Color.FromArgb(235, 170, 70),
                    "not shared" => Color.Gray,
                    _ => Color.FromArgb(230, 120, 120),
                };
                watchedCard.Controls.Add(new Label
                {
                    Text = $"{row.Email} — {detail}" + (row.ReadCount > 0 ? $" · read {row.ReadCount}×" : ""),
                    ForeColor = color,
                    Dock = DockStyle.Top,
                    Height = 22,
                    TextAlign = ContentAlignment.MiddleLeft,
                    Padding = new Padding(8, 0, 0, 0),
                });
            }

            _flow.Controls.Add(watchedCard);
            height += watchedCard.Height + 6;
        }

        if (_updateInfo() is { } update)
        {
            var banner = new LinkLabel
            {
                Text = $"New release available: v{update.Version} — view on GitHub",
                LinkColor = Color.FromArgb(120, 170, 255),
                Width = statusCard.Width,
                Height = 24,
                Padding = new Padding(8, 4, 0, 0),
                BackColor = Color.FromArgb(42, 42, 47),
            };
            banner.Click += (_, _) =>
            {
                if (update.ReleaseUrl is { } url)
                {
                    _ = url;
                    System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true });
                }
            };
            _flow.Controls.Add(banner);
            height += banner.Height + 6;
        }

        var footer = new Panel { Width = statusCard.Width, Height = 36, BackColor = Color.Transparent };
        var settingsButton = MakeLink("Settings", 4, _openSettings);
        var refreshButton = MakeLink("Refresh", 76, () => _ = _orchestrator.RefreshAsync(CancellationToken.None));
        footer.Controls.Add(settingsButton);
        footer.Controls.Add(refreshButton);
        _flow.Controls.Add(footer);
        height += footer.Height;

        _flow.ResumeLayout();
        Height = Math.Min(height + 12, 760);
        PositionNearTray();
    }

    private IEnumerable<ProviderKind> OrderedKinds()
    {
        var order = new List<ProviderKind>();
        foreach (var name in ProgramSettings.Current.CustomProviderOrder)
        {
            if (Enum.TryParse<ProviderKind>(name, true, out var kind))
            {
                order.Add(kind);
            }
        }

        foreach (ProviderKind kind in Enum.GetValues(typeof(ProviderKind)))
        {
            if (!order.Contains(kind))
            {
                order.Add(kind);
            }
        }

        return order;
    }

    private Control BuildProviderCard(ProviderKind kind, ProviderSnapshot? snapshot)
    {
        var card = new Panel
        {
            Width = _flow.ClientSize.Width - _flow.Padding.Horizontal - 8,
            Height = 66,
            BackColor = Color.FromArgb(42, 42, 47),
        };

        var title = new Label
        {
            Text = kind.DisplayName(),
            ForeColor = Color.Gainsboro,
            Font = new Font("Segoe UI Semibold", 9.5f),
            Location = new Point(10, 6),
            AutoSize = true,
        };
        card.Controls.Add(title);

        if (snapshot is null || snapshot.Status is ProviderStatus.Idle or ProviderStatus.Loading)
        {
            card.Controls.Add(new Label
            {
                Text = snapshot?.Status == ProviderStatus.Loading ? "Refreshing…" : "No data yet",
                ForeColor = Color.Gray,
                Location = new Point(10, 28),
                AutoSize = true,
            });
            return card;
        }

        if (snapshot.Status is ProviderStatus.Failed or ProviderStatus.Offline)
        {
            card.Controls.Add(new Label
            {
                Text = snapshot.Error is null ? "Unavailable" : Truncate(snapshot.Error, 52),
                ForeColor = Color.FromArgb(230, 120, 120),
                Location = new Point(10, 28),
                AutoSize = true,
            });
            return card;
        }

        var account = snapshot.Accounts.FirstOrDefault();
        var window = account?.Windows.FirstOrDefault();
        if (window is null)
        {
            card.Controls.Add(new Label
            {
                Text = "No quota window",
                ForeColor = Color.Gray,
                Location = new Point(10, 28),
                AutoSize = true,
            });
            return card;
        }

        var remaining = Math.Clamp(window.RemainingPercent, 0, 100);
        var color = remaining switch
        {
            < QuotaThresholds.RedRemainingPercent => Color.FromArgb(235, 90, 90),
            < QuotaThresholds.OrangeRemainingPercent => Color.FromArgb(235, 170, 70),
            _ => Color.FromArgb(110, 200, 140),
        };
        var remainingSeconds = Math.Max(0, (window.ResetsAtUtc - DateTimeOffset.UtcNow).TotalSeconds);
        var main = new Label
        {
            Text = $"{remaining:0}% left · {TimeText.FormatRemaining(TimeSpan.FromSeconds(remainingSeconds))}",
            ForeColor = color,
            Font = new Font("Segoe UI", 12f, FontStyle.Bold),
            Location = new Point(10, 24),
            AutoSize = true,
        };
        card.Controls.Add(main);

        var secondary = snapshot.Accounts.FirstOrDefault()?.Windows.Skip(1).FirstOrDefault();
        var pace = PaceMath.Compute(window, DateTimeOffset.UtcNow);
        var paceText = pace is null ? "" : (pace.IsReserve ? "reserve " : "deficit ") + $"{pace.DeltaPercent:+0.0;-0.0}pp";
        var meta = $"{window.Name} · resets {window.ResetsAtUtc.ToLocalTime():MM/dd HH:mm}";
        if (secondary is not null)
        {
            meta += $" · {secondary.Name} {secondary.RemainingPercent:0}%";
        }

        card.Controls.Add(new Label
        {
            Text = string.IsNullOrEmpty(paceText) ? meta : $"{meta} · {paceText}",
            ForeColor = pace is { IsReserve: false, Bucket: PaceBucket.Far } ? Color.FromArgb(235, 120, 120) : Color.Gray,
            Location = new Point(10, 44),
            AutoSize = true,
        });

        if (account is { Label.Length: > 0 } && !string.IsNullOrEmpty(account.Label))
        {
            title.Text = $"{kind.DisplayName()} · {account.Label}";
        }

        if (!string.IsNullOrEmpty(snapshot.SubscribeTitle))
        {
            var badge = new Label
            {
                Text = snapshot.SubscribeTitle + (string.IsNullOrEmpty(snapshot.SubscribeEndTimeText) ? "" : $" · {snapshot.SubscribeEndTimeText}"),
                ForeColor = Color.DimGray,
                Location = new Point(card.Width - 130, 8),
                AutoSize = true,
                Anchor = AnchorStyles.Top | AnchorStyles.Right,
            };
            card.Controls.Add(badge);
        }

        return card;
    }

    private LinkLabel MakeLink(string text, int x, Action onClick)
    {
        var link = new LinkLabel
        {
            Text = text,
            LinkColor = Color.FromArgb(120, 170, 255),
            Location = new Point(x, 6),
            AutoSize = true,
        };
        link.Click += (_, _) => onClick();
        return link;
    }

    private void PositionNearTray()
    {
        var screen = Screen.PrimaryScreen?.WorkingArea ?? SystemInformation.WorkingArea;
        Location = new Point(screen.Right - Width - 12, screen.Bottom - Height - 12);
    }

    private static string Truncate(string text, int max) => text.Length <= max ? text : text[..(max - 1)] + "…";

    private static string FormatBps(double bps) => bps >= 1_000_000
        ? $"{bps / 1_000_000:0.0}MB/s"
        : bps >= 1_000 ? $"{bps / 1_000:0.0}kB/s" : $"{bps:0}B/s";

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _orchestrator.SnapshotsChanged -= OnSnapshotsChanged;
            _refreshTimer.Stop();
        }

        base.Dispose(disposing);
    }
}
