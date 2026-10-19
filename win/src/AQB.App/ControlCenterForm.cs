using AQB.Core;
using AQB.Providers.Codex;

namespace AQB.App;

/// <summary>
/// Left-click control center, redesigned to the macOS panel's information dimensions on a
/// native Windows flyout chassis: system dark/light palette, rounded cards, collapsible
/// sections with persisted state, capsule bars + trend sparklines per window, account
/// groups, local usage card, watched accounts, route/connection summary.
/// All layout constants are expressed in 96-dip units and scaled by <see cref="P"/>.
/// </summary>
internal sealed class ControlCenterForm : Form
{
    private readonly QuotaOrchestrator _orchestrator;
    private readonly NativePalette _palette = NativePalette.System();
    private readonly Action _openSettings;
    private readonly Action _openClash;
    private readonly Action _openConnections;
    private readonly Func<HostState> _state;
    private readonly FlowLayoutPanel _flow = new();

    public ControlCenterForm(
        QuotaOrchestrator orchestrator,
        Action openSettings,
        Action openClash,
        Action openConnections,
        Func<HostState> state)
    {
        _orchestrator = orchestrator;
        _openSettings = openSettings;
        _openClash = openClash;
        _openConnections = openConnections;
        _state = state;

        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        AutoScaleMode = AutoScaleMode.None;
        BackColor = _palette.Background;
        Size = new Size(P(360), P(60));
        Font = new Font("Segoe UI", 9f);

        _flow.Dock = DockStyle.None;
        _flow.BackColor = _palette.Background;
        _flow.FlowDirection = FlowDirection.TopDown;
        _flow.WrapContents = false;
        _flow.Padding = new Padding(P(10));
        Controls.Add(_flow);
        _pill.Palette = _palette;
        Controls.Add(_pill);

        _orchestrator.SnapshotsChanged += OnSnapshotsChanged;
        _refreshTimer.Tick += (_, _) => Rebuild();
        _refreshTimer.Start();
        Rebuild();
    }

    private readonly System.Windows.Forms.Timer _refreshTimer = new() { Interval = 30_000 };
    private readonly ToolTip _tips = new();
    private readonly ScrollPill _pill = new();
    private bool _scrollable;
    private int _scrollOffset;

    protected override void OnMouseWheel(MouseEventArgs e)
    {
        base.OnMouseWheel(e);
        if (_scrollable)
        {
            SetScrollOffset(_scrollOffset - e.Delta / 120 * P(56));
        }
    }

    private void SetScrollOffset(int value)
    {
        var max = Math.Max(0, _flow.Height - ClientSize.Height);
        var clamped = Math.Clamp(value, 0, max);
        _scrollable = max > 0;
        _scrollOffset = clamped;
        _flow.Top = -clamped;
        UpdatePill();
    }

    private void UpdatePill()
    {
        if (!_scrollable)
        {
            _pill.Visible = false;
            return;
        }

        var trackTop = P(6);
        var trackHeight = ClientSize.Height - P(12);
        var content = _flow.Height;
        var pillHeight = Math.Max(P(28), (int)((long)trackHeight * ClientSize.Height / content));
        var y = trackTop + (int)((trackHeight - pillHeight) * (_scrollOffset / (double)Math.Max(1, content - ClientSize.Height)));
        _pill.Bounds = new Rectangle(ClientSize.Width - P(8), y, P(4), pillHeight);
        _pill.Visible = true;
        _pill.Invalidate();
    }

    /// <summary>Dip → pixel scale for the current monitor.</summary>
    private float Scale => DeviceDpi / 96f;

    private int P(int dip) => (int)Math.Round(dip * Scale);

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        NativeChrome.ApplyRounded(this);
        NativeChrome.ApplyBorderlessShadow(this);
        PositionNearTray();
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        if (!SuppressAutoClose)
        {
            NativeChrome.ForceForeground(this);
        }
    }

    /// <summary>Set by the screenshot self-check so the flyout does not auto-close without focus.</summary>
    public bool SuppressAutoClose { get; set; }

    protected override void OnDeactivate(EventArgs e)
    {
        base.OnDeactivate(e);
        if (!SuppressAutoClose)
        {
            Close();
        }
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

    private void OnSnapshotsChanged()
    {
        if (IsHandleCreated)
        {
            BeginInvoke(Rebuild);
        }
    }

    private int CardWidth => P(340);

    private void Rebuild()
    {
        if (IsDisposed)
        {
            return;
        }

        var state = _state();
        _flow.SuspendLayout();
        _flow.Controls.Clear();

        AddCard(BuildHeader(state));
        var providerCards = 0;
        foreach (var kind in OrderedKinds())
        {
            if (!_orchestrator.IsConfigured(kind))
            {
                continue; // 未配置的供应商不显示卡片,与 macOS 菜单只显示已连接分区一致
            }

            var snapshot = _orchestrator.Latest.GetValueOrDefault(kind);
            if (BuildProviderCard(kind, snapshot, state) is { } card)
            {
                AddCard(card);
                providerCards++;
            }
        }

        if (providerCards == 0)
        {
            var hint = MakeCard();
            hint.Controls.Add(WrappedLabel("尚未连接任何服务商 — 添加 API key 或登录后,这里会显示额度、趋势和用量。", _palette.TextFaint, 14, 10));
            var open = MakeLink("打开设置", () => _openSettings());
            open.Location = new Point(P(14), P(44));
            hint.Controls.Add(open);
            AddCard(hint);
        }

        if (BuildWatchedCard(state) is { } watchedCard)
        {
            AddCard(watchedCard);
        }

        AddCard(BuildStatusCard(state));

        if (state.UpdateInfo is { } update)
        {
            var banner = MakeCard();
            var link = new LinkLabel
            {
                Text = $"新版本可用:v{update.Version} — 查看发布页",
                LinkColor = _palette.IsDark ? Color.FromArgb(120, 170, 255) : Color.FromArgb(40, 110, 220),
                ForeColor = _palette.TextPrimary,
                Location = new Point(P(12), P(8)),
                AutoSize = true,
                Cursor = Cursors.Hand,
            };
            link.Click += (_, _) =>
            {
                if (update.ReleaseUrl is { } url)
                {
                    _ = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true });
                }
            };
            banner.Controls.Add(link);
            AddCard(banner);
        }

        AddCard(BuildFooter());
        _flow.ResumeLayout();

        // Adaptive height: content height clamped to the screen's usable area near
        // the tray; overflow scrolls by wheel with a thin pill indicator (Win11
        // flyout convention) instead of the classic scrollbar + reserved gutter.
        var padding = _flow.Padding;
        var contentHeight = padding.Vertical
            + _flow.Controls.Cast<Control>().Sum(c => c.Height + c.Margin.Vertical);
        var available = (Screen.PrimaryScreen?.WorkingArea ?? SystemInformation.WorkingArea).Height - P(24);
        Height = Math.Clamp(contentHeight, P(320), Math.Max(P(320), available));
        _flow.SetBounds(0, 0, ClientSize.Width, contentHeight);
        SetScrollOffset(_scrollOffset);
        PositionNearTray();
    }

    private void AddCard(CardPanel card)
    {
        card.FitToContent(Scale);

        // Icon buttons center vertically in their card instead of hugging the title line.
        foreach (Control control in card.Controls)
        {
            if (control is IconButton button)
            {
                button.Location = new Point(button.Location.X, Math.Max(0, (card.Height - button.Height) / 2));
            }
        }

        _flow.Controls.Add(card);
    }

    private CardPanel BuildHeader(HostState state)
    {
        var card = MakeCard();
        var snapshots = _orchestrator.Latest;
        var updated = snapshots.Values
            .Where(s => s.LastUpdatedUtc is not null)
            .OrderByDescending(s => s.LastUpdatedUtc)
            .FirstOrDefault()?.LastUpdatedUtc;
        var updatedText = updated is { } at ? TimeText.FormatRelativeAge(DateTimeOffset.UtcNow - at) : "—";
        var nextIn = (int)Math.Ceiling(((updated ?? DateTimeOffset.UtcNow)
            .AddSeconds(ProgramSettings.Current.UsageRefreshIntervalSeconds) - DateTimeOffset.UtcNow).TotalMinutes);
        // A refresh can be overdue (slow or failing fetches); never show a negative countdown.
        var nextText = nextIn >= 1 ? $"下次约 {nextIn} 分钟后" : "即将刷新";

        card.Controls.Add(Label("AI Quota Bar", new Font("Segoe UI Semibold", 10.5f), _palette.TextPrimary, 14, 8));
        var meta = Label($"更新于 {updatedText} · {nextText}", Font, _palette.TextFaint, 14, 30);
        meta.MaximumSize = new Size(card.Width - P(124), 0); // wraps before the icon buttons
        card.Controls.Add(meta);

        // Refresh + close as flat glyph buttons, Windows 11 flyout convention.
        const string chromeClose = "\uE8BB";
        const string refreshGlyph = "\uE72C";
        var close = new IconButton(chromeClose)
        {
            Palette = _palette,
            Bounds = new Rectangle(card.Width - P(16) - P(28), P(8), P(28), P(28)),
            Anchor = AnchorStyles.Top | AnchorStyles.Right,
        };
        close.Click += (_, _) => Close();
        var refresh = new IconButton(refreshGlyph)
        {
            Palette = _palette,
            Bounds = new Rectangle(card.Width - P(16) - P(60), P(8), P(28), P(28)),
            Anchor = AnchorStyles.Top | AnchorStyles.Right,
        };
        refresh.Click += (_, _) => _ = _orchestrator.RefreshAsync(CancellationToken.None);
        card.Controls.Add(close);
        card.Controls.Add(refresh);
        _tips.SetToolTip(close, "关闭");
        _tips.SetToolTip(refresh, "立即刷新");
        return card;
    }

    private CardPanel? BuildProviderCard(ProviderKind kind, ProviderSnapshot? snapshot, HostState state)
    {
        var collapsed = IsCollapsed(kind.WireName());
        var card = MakeCard();
        const int headerBottom = 44;

        var chevron = new Label
        {
            Text = collapsed ? "▸" : "▾",
            Font = new Font("Segoe UI", 10f),
            ForeColor = _palette.TextFaint,
            BackColor = Color.Transparent,
            Location = new Point(P(12), P(11)),
            AutoSize = true,
            Cursor = Cursors.Hand,
        };
        chevron.Click += (_, _) => ToggleCollapsed(kind.WireName());
        card.Controls.Add(chevron);
        card.Controls.Add(Label(kind.DisplayName(), new Font("Segoe UI Semibold", 10f), _palette.TextPrimary, 36, 8));

        if (snapshot is not null)
        {
            var account = snapshot.Accounts.FirstOrDefault();
            if (account is { Label.Length: > 0 })
            {
                // Raw label (email or provider name) — masking is only for the remote dashboard.
                var accountLabel = Label(account.Label, Font, _palette.TextFaint, 36, 24);
                _tips.SetToolTip(accountLabel, $"{account.SourceLabel} · {snapshot.LastUpdatedUtc?.ToLocalTime():MM-dd HH:mm}");
                card.Controls.Add(accountLabel);
            }

            var badgeText = (snapshot.SubscribeTitle ?? account?.PlanTitle) is { Length: > 0 } subscribe
                ? subscribe + (string.IsNullOrEmpty(snapshot.SubscribeEndTimeText) ? "" : $" · {snapshot.SubscribeEndTimeText}")
                : null;
            if (badgeText is not null)
            {
                var badge = Label(badgeText, Font, _palette.TextFaint, 0, 12);
                badge.Anchor = AnchorStyles.Top | AnchorStyles.Right;
                badge.Location = new Point(card.Width - P(16) - badge.PreferredWidth, P(12));
                card.Controls.Add(badge);
            }
        }
        else
        {
            card.Controls.Add(Label("等待数据…", Font, _palette.TextFaint, 36, 26));
        }

        if (collapsed)
        {
            if (snapshot?.Accounts.FirstOrDefault()?.Windows.FirstOrDefault() is { } primary)
            {
                var big = Label($"{primary.RemainingPercent:0}%", new Font("Segoe UI", 11f, FontStyle.Bold), _palette.QuotaColor(primary.RemainingPercent), 0, 0);
                big.Anchor = AnchorStyles.Top | AnchorStyles.Right;
                big.Location = new Point(card.Width - P(16) - big.PreferredWidth, P(26));
                card.Controls.Add(big);
            }

            return card;
        }

        var top = headerBottom + 10;

        // Local usage lives inside the Codex section (mac CodexLocalUsageMenuCard sits
        // under the account header, before the quota rows) and collapses with it. It
        // renders even without quota data — it reads the local session logs.
        if (kind == ProviderKind.Codex && state.Usage is { } usage)
        {
            card.Controls.Add(Label("本机用量", new Font("Segoe UI Semibold", 9.5f), _palette.TextSecondary, 16, top));
            card.Controls.Add(Label($"今日 {usage.TodayTokensText} · 35 天 {usage.TotalTokensText}", Font, _palette.TextFaint, 16, top + 17));
            card.Controls.Add(Label(
                $"缓存命中 {usage.CacheHitRateText}" + (usage.CostText is { } cost ? $" · 成本 {cost}" : ""),
                Font, _palette.TextFaint, 16, top + 34));
            top += 52;
        }

        if (snapshot is null || snapshot.Status is ProviderStatus.Failed or ProviderStatus.Offline)
        {
            if (snapshot is null)
            {
                return card;
            }

            var hasPrevious = snapshot.Status == ProviderStatus.Failed
                && snapshot.Accounts.Any(a => a.Windows.Count > 0);
            var warning = WrappedLabel(EmptyStateText(kind, snapshot)
                + (hasPrevious ? $"\n显示上次成功数据（{snapshot.LastUpdatedUtc?.ToLocalTime():MM-dd HH:mm}）" : ""),
                _palette.IsDark ? Color.FromArgb(235, 130, 130) : Color.FromArgb(180, 60, 60), 14, top);
            _tips.SetToolTip(warning, snapshot.Error);
            card.Controls.Add(warning);
            if (!hasPrevious) return card;
            top += (int)Math.Ceiling(warning.GetPreferredSize(new Size(CardWidth - P(28), 0)).Height / Scale) + 10;
        }

        var account2 = snapshot.Accounts.FirstOrDefault();

        // Quota rows in the macOS ModelRow shape: header (name + big tinted percent),
        // then EITHER the cycle area chart (short window with in-window samples) OR a
        // compact capsule — never both, one information one chart; a metadata line;
        // cross-cycle bars last. MiniMax's interval+weekly windows describe one pool,
        // so weekly folds into the 5h row's metadata like macOS does.
        var windows = account2?.Windows ?? Array.Empty<QuotaWindowSample>();
        if (windows.Count == 0)
        {
            card.Controls.Add(WrappedLabel("暂无配额窗口 — 保存凭据后自动刷新", _palette.TextFaint, 14, top));
            return card;
        }

        var foldWeeklyIntoMeta = kind == ProviderKind.MiniMax
            && windows.Any(IsShortWindow)
            && windows.Any(w => !IsShortWindow(w));
        QuotaWindowSample? weeklyMeta = foldWeeklyIntoMeta
            ? windows.FirstOrDefault(w => !IsShortWindow(w))
            : null;

        foreach (var window in windows)
        {
            if (foldWeeklyIntoMeta && !IsShortWindow(window))
            {
                continue;
            }

            top = AddQuotaRow(card, kind, window, IsShortWindow(window), weeklyMeta, state, top);
        }

        // Per-model usage rows (top 3): only models actually consumed — rows that
        // never spent anything (models outside the plan) are noise, Mac keeps them
        // only to paint a red dash.
        foreach (var model in snapshot.Models
                     .Where(m => m.UsedPercent > 0)
                     .OrderByDescending(m => m.UsedPercent)
                     .Take(3))
        {
            card.Controls.Add(EllipsizedLabel("· " + model.ModelName, Font, _palette.TextSecondary, 14, top, card.Width - P(160), hand: false));
            card.Controls.Add(new CapsuleBar
            {
                Palette = _palette,
                Bounds = new Rectangle(card.Width - P(136), P(top + 5), P(120), P(6)),
                Percent = 100 - model.UsedPercent,
            });
            top += 21;
        }

        // Additional account rows (Codex pool).
        foreach (var other in snapshot.Accounts.Skip(1))
        {
            card.Controls.Add(EllipsizedLabel(other.Label, Font, _palette.TextSecondary, 14, top, card.Width - P(80), hand: false));
            if (other.Windows.FirstOrDefault() is { } otherWindow)
            {
                var value = Label($"{otherWindow.RemainingPercent:0}%", new Font("Segoe UI", 9f, FontStyle.Bold), _palette.QuotaColor(otherWindow.RemainingPercent), 0, top);
                value.Anchor = AnchorStyles.Top | AnchorStyles.Right;
                value.Location = new Point(card.Width - P(16) - value.PreferredWidth, P(top));
                card.Controls.Add(value);
            }

            top += 22;
        }

        return card;
    }

    /// <summary>Short cycle (&lt; 24h) — the chartable kind on macOS; detected from the
    /// window span when known, otherwise from the name ("5h").</summary>
    private static bool IsShortWindow(QuotaWindowSample window)
    {
        if (window.ResetsAtUtc > DateTimeOffset.MinValue)
        {
            var span = window.ResetsAtUtc - window.WindowStartUtc;
            if (span > TimeSpan.Zero)
            {
                return span < TimeSpan.FromHours(24);
            }
        }

        var name = window.Name ?? "";
        return name.Contains("5h", StringComparison.OrdinalIgnoreCase)
            || name.Contains("5 小时", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>One quota window as a macOS-style row: header → chart-or-capsule →
    /// metadata → cross-cycle bars. Returns the next free y (in dips).</summary>
    private int AddQuotaRow(
        CardPanel card,
        ProviderKind kind,
        QuotaWindowSample window,
        bool isShort,
        QuotaWindowSample? weeklyMeta,
        HostState state,
        int top)
    {
        var tint = _palette.QuotaColor(window.RemainingPercent);

        // Header: window name left, big tinted remaining percent right.
        card.Controls.Add(EllipsizedLabel(window.Name, new Font("Segoe UI", 9.5f), _palette.TextSecondary, 16, top, card.Width / 2, hand: false));
        var percent = Label($"{window.RemainingPercent:0}%", new Font("Segoe UI", 12f, FontStyle.Bold), tint, 0, top - 3);
        percent.Anchor = AnchorStyles.Top | AnchorStyles.Right;
        percent.Location = new Point(card.Width - P(16) - percent.PreferredWidth, P(top - 3));
        card.Controls.Add(percent);
        top += 24;

        var series = state.History?.GetSeries(kind, window.Name) ?? Array.Empty<QuotaSamplePoint>();

        // Chart x axis = the cycle itself. Rolling windows (GLM 5h) anchor to
        // (now-5h, now) exactly like macOS and never get a pace diagonal.
        DateTimeOffset start, end;
        bool rolling;
        if (isShort && kind == ProviderKind.Glm)
        {
            end = DateTimeOffset.UtcNow;
            start = end.AddHours(-5);
            rolling = true;
        }
        else
        {
            end = window.ResetsAtUtc > DateTimeOffset.MinValue ? window.ResetsAtUtc : DateTimeOffset.UtcNow;
            start = window.WindowStartUtc;
            var span = end - start;
            rolling = (window.WindowSeconds <= 0 && window.StartsAtUtc is null) || span <= TimeSpan.Zero;
            if (rolling)
            {
                start = end.AddHours(-5);
            }
        }

        var pace = rolling ? null : PaceMath.Compute(start, end, DateTimeOffset.UtcNow, window.UsedPercent);
        var inWindow = series.Count(p => p.AtUtc >= start && p.AtUtc <= end);
        if (isShort && inWindow >= 2)
        {
            card.Controls.Add(new QuotaAreaChart
            {
                Palette = _palette,
                Bounds = new Rectangle(P(16), P(top), card.Width - P(32), P(80)),
                Points = series,
                WindowStart = start,
                WindowEnd = end,
                PaceIsReserve = pace?.IsReserve,
            });
            top += 84;
        }
        else
        {
            card.Controls.Add(new CapsuleBar
            {
                Palette = _palette,
                Bounds = new Rectangle(P(16), P(top + 2), card.Width - P(32), P(6)),
                Percent = window.RemainingPercent,
            });
            top += 12;
        }

        // Metadata line: pace deviation on short rows (only off schedule — macOS hides
        // on-track pace), reset time on long rows, MiniMax's weekly info last.
        var metaFont = new Font("Segoe UI", 8.5f);
        var metaX = 16;
        if (isShort && pace is { } p && p.Bucket != PaceBucket.OnTrack)
        {
            var paceColor = p.IsReserve
                ? (_palette.IsDark ? Color.FromArgb(96, 200, 145) : Color.FromArgb(35, 150, 95))
                : Color.FromArgb(235, 170, 70);
            var paceLabel = Label((p.IsReserve ? "结余 " : "亏空 ") + $"{p.DeltaPercent:+0.0;-0.0}pp", metaFont, paceColor, metaX, top);
            card.Controls.Add(paceLabel);
            metaX += paceLabel.PreferredWidth + 8;
        }

        if (!isShort && window.ResetsAtUtc > DateTimeOffset.MinValue)
        {
            var resetText = "重置 " + window.ResetsAtUtc.ToLocalTime().ToString("MM-dd HH:mm");
            card.Controls.Add(Label(resetText, metaFont, _palette.TextFaint, metaX, top));
            metaX += TextRenderer.MeasureText(resetText, metaFont).Width + 8;
        }

        if (weeklyMeta is not null)
        {
            var weeklyText = $"周 {weeklyMeta.RemainingPercent:0}%"
                + (weeklyMeta.ResetsAtUtc > DateTimeOffset.MinValue
                    ? " · 重置 " + weeklyMeta.ResetsAtUtc.ToLocalTime().ToString("MM-dd HH:mm")
                    : "");
            card.Controls.Add(Label(weeklyText, metaFont, _palette.TextFaint, metaX, top));
        }

        top += 16;

        // Cross-cycle utilization bars (mac ModelUtilizationBarsView): one bar per
        // cycle, height = peak used percent; only meaningful under a chart row.
        if (isShort && inWindow >= 2)
        {
            card.Controls.Add(new UtilizationBars
            {
                Palette = _palette,
                Bounds = new Rectangle(P(16), P(top), card.Width - P(32), P(24)),
                Cycles = CycleDetection.Detect(series),
            });
            top += 28;
        }

        return top + 8;
    }

    private CardPanel? BuildWatchedCard(HostState state)
    {
        var rows = state.WatchedRows;
        if (rows.Count == 0)
        {
            return null;
        }

        var card = MakeCard();
        card.Controls.Add(Label("关注的账号", new Font("Segoe UI Semibold", 9.5f), _palette.TextPrimary, 14, 9));
        var top = 30;
        foreach (var row in rows)
        {
            var detail = row.StatusText == "available" && row.RemainingPercent is { } remaining
                ? $"{remaining:0}% · {row.WindowName ?? ""} · {row.ResetsAtText ?? ""}"
                : row.StatusText;
            var color = row.StatusText switch
            {
                "available" => _palette.IsDark ? Color.FromArgb(96, 200, 145) : Color.FromArgb(35, 150, 95),
                "stale" => Color.FromArgb(235, 170, 70),
                "not shared" => _palette.TextFaint,
                _ => Color.FromArgb(232, 90, 90),
            };
            card.Controls.Add(EllipsizedLabel($"{row.Email} — {detail}" + (row.ReadCount > 0 ? $" · 被读 {row.ReadCount} 次" : ""), Font, color, 14, top, card.Width - P(28), hand: false));
            top += 22;
        }

        return card;
    }

    private CardPanel BuildStatusCard(HostState state)
    {
        var (status, tasks, providers) = state.Protection;
        var (group, selected, delayMs) = state.Route;
        var (openAi, upBps, downBps) = state.Connection;

        var hasTasks = tasks > 0;
        var hasRoute = !string.IsNullOrEmpty(group);
        var card = MakeCard();
        var top = 9;

        if (hasTasks)
        {
            card.Controls.Add(Label($"活动任务 {tasks}({providers})· 防睡眠 {status}", Font,
                _palette.IsDark ? Color.FromArgb(96, 200, 145) : Color.FromArgb(35, 150, 95), 14, top));
            top += 19;
        }

        if (hasRoute)
        {
            var route = EllipsizedLabel($"路由 {group} → {selected ?? "—"}{(delayMs is > 0 ? $"({delayMs}ms)" : "")}", _palette.TextPrimary, 14, top);
            route.Click += (_, _) => { _openClash(); Close(); };
            card.Controls.Add(route);
            top += 19;
            var conn = EllipsizedLabel($"OpenAI 连接 {openAi} · ↓{FormatBps(downBps)} ↑{FormatBps(upBps)}", _palette.TextFaint, 14, top);
            conn.Click += (_, _) => { _openConnections(); Close(); };
            card.Controls.Add(conn);
            top += 19;
            card.Controls.Add(Label(
                state.DashboardRunning ? $"手机看板运行中 :{state.DashboardPort}" : "手机看板未启用(设置中开启)",
                Font, _palette.TextFaint, 14, top));
        }
        else
        {
            var line = EllipsizedLabel("Clash 控制器未发现 · 点击打开连接面板", _palette.TextFaint, 14, top);
            line.Click += (_, _) => { _openConnections(); Close(); };
            card.Controls.Add(line);
        }

        return card;
    }

    private CardPanel BuildFooter()
    {
        var footer = MakeCard();
        footer.Height = P(36);
        var settings = MakeLink("设置", () => _openSettings());
        settings.Location = new Point(P(10), P(7));
        var clash = MakeLink("Clash 路由", _openClash);
        clash.Location = new Point(P(64), P(7));
        var quit = MakeLink("退出", Application.Exit);
        quit.Anchor = AnchorStyles.Top | AnchorStyles.Right;
        quit.Location = new Point(footer.Width - P(10) - quit.PreferredWidth, P(7));
        footer.Controls.Add(settings);
        footer.Controls.Add(clash);
        footer.Controls.Add(quit);
        return footer;
    }

    private Label EllipsizedLabel(string text, Color color, int x, int y) =>
        EllipsizedLabel(text, Font, color, x, y, CardWidth - P(28), hand: true);

    /// <summary>Single-line ellipsizing label. Height is measured from the font because the
    /// default Label height is unscaled and clips 9pt text in half at 200% DPI.</summary>
    private Label EllipsizedLabel(string text, Font font, Color color, int x, int y, int widthPx, bool hand = true) => new()
    {
        Text = text,
        Font = font,
        ForeColor = color,
        BackColor = Color.Transparent,
        Bounds = new Rectangle(P(x), P(y), widthPx, TextRenderer.MeasureText(text, font).Height),
        AutoSize = false,
        AutoEllipsis = true,
        Cursor = hand ? Cursors.Hand : Cursors.Default,
    };

    private bool IsCollapsed(string section) =>
        ProgramSettings.Current.CollapsedSections.Contains(section, StringComparer.OrdinalIgnoreCase);

    private void ToggleCollapsed(string section)
    {
        var settings = ProgramSettings.Current;
        settings.CollapsedSections = settings.CollapsedSections.Contains(section, StringComparer.OrdinalIgnoreCase)
            ? settings.CollapsedSections.Where(s => !string.Equals(s, section, StringComparison.OrdinalIgnoreCase)).ToList()
            : settings.CollapsedSections.Append(section).ToList();
        settings.Save();
        Rebuild();
    }

    /// <summary>
    /// 已配置但抓取失败时展示真实错误(对齐 macOS 菜单的 "&lt;Provider&gt;: error" 警示行),
    /// 引导文案只在真正缺少凭据时出现 — 否则网络故障会被误读成"未登录"。
    /// </summary>
    private string EmptyStateText(ProviderKind kind, ProviderSnapshot snapshot)
    {
        if (snapshot.Error is { Length: > 0 }
            && snapshot.Error != QuotaOrchestrator.NotConfiguredError
            && snapshot.Error != CodexQuotaService.NoCredentialsError)
        {
            return "获取失败:" + Truncate(snapshot.Error, 90);
        }

        return kind switch
        {
            ProviderKind.Codex => "未找到 ~/.codex 凭据 — 登录 Codex 后自动识别",
            ProviderKind.Glm => "未配置 — 设置 → Providers → GLM 填入 API key",
            ProviderKind.MiniMax => "未配置 — 设置 → Providers → MiniMax 填入 token",
            ProviderKind.Kimi => "未找到可用会话",
            _ => "不可用",
        };
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

    private CardPanel MakeCard() => new()
    {
        Palette = _palette,
        Width = CardWidth,
        Height = P(44),
        Margin = new Padding(0, 0, 0, P(8)),
    };

    private Label Label(string text, Font font, Color color, int x, int y) => new()
    {
        Text = text,
        Font = font,
        ForeColor = color,
        BackColor = Color.Transparent,
        Location = new Point(P(x), P(y)),
        AutoSize = true,
    };

    private Label WrappedLabel(string text, Color color, int x, int y) => new()
    {
        Text = text,
        Font = Font,
        ForeColor = color,
        BackColor = Color.Transparent,
        Location = new Point(P(x), P(y)),
        MaximumSize = new Size(CardWidth - P(28), 0),
        AutoSize = true,
    };

    private LinkLabel MakeLink(string text, Action onClick)
    {
        var link = new LinkLabel
        {
            Text = text,
            LinkColor = _palette.IsDark ? Color.FromArgb(120, 170, 255) : Color.FromArgb(40, 110, 220),
            BackColor = Color.Transparent,
            AutoSize = true,
            Cursor = Cursors.Hand,
        };
        link.Click += (_, _) => onClick();
        return link;
    }

    private void PositionNearTray()
    {
        var screen = Screen.PrimaryScreen?.WorkingArea ?? SystemInformation.WorkingArea;
        Location = new Point(screen.Right - Width - P(12), screen.Bottom - Height - P(12));
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
            _tips.Dispose();
        }

        base.Dispose(disposing);
    }
}

/// <summary>Rounded card surface that sizes its height to its content.</summary>
internal sealed class CardPanel : Panel
{
    public NativePalette Palette { get; init; } = NativePalette.System();

    public CardPanel()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
    }

    public void FitToContent(float scale)
    {
        var bottom = Controls.Count == 0 ? Height : Controls.Cast<Control>().Max(c => c.Bottom);
        Height = Math.Max(Height, bottom + (int)Math.Round(10 * scale));
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        var bounds = new Rectangle(0, 0, Width - 1, Height - 1);
        Gdi.FillRounded(g, Palette.Card, bounds, 8);
        Gdi.DrawRoundedBorder(g, Palette.CardBorder, bounds, 8);
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        // Fill with the flyout background so the corners outside the rounded
        // card blend in instead of showing the default SystemColors.Control gray.
        using var brush = new SolidBrush(Palette.Background);
        e.Graphics.FillRectangle(brush, e.ClipRectangle);
    }
}
