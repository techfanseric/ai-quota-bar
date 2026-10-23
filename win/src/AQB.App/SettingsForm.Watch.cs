using AQB.Core;
using AQB.Providers.Codex;
using AQB.Team;

namespace AQB.App;

internal sealed partial class SettingsForm
{
    private Control BuildCodexWatchSection()
    {
        var section = WatchLayout();
        var heading = WatchLabel("Codex · 账号分享与关注");
        heading.Font = new Font(Font, FontStyle.Bold);
        section.Controls.Add(heading);
        section.Controls.Add(WatchLabel("Watch 设置即时保存。知道邮箱的 AI Quota Bar 用户可读取你勾选分享的额度；登录凭据不会上传。无需团队、邀请码或在关注方登录 Codex。"));
        section.Controls.Add(WatchLabel("只有本机实际获取到额度的账号会发布。账号池中尚未获取额度的账号，需要先在本机登录并刷新。默认不分享任何账号。"));

        var sharing = new CheckBox
        {
            Text = "允许其他设备关注我的 Codex 账号",
            AutoSize = true,
            Checked = _settings.CodexWatchSharingEnabled,
        };
        section.Controls.Add(sharing);
        var accounts = WatchLayout();
        section.Controls.Add(accounts);
        var reads = WatchLabel("");
        section.Controls.Add(reads);
        string? accountSignature = null;
        void SaveWatch()
        {
            _settings.Save();
            _refreshWatch();
        }
        void UpdateAccounts()
        {
            // Only local snapshots and the local account pool may supply share choices.
            // Keep previously selected addresses visible so they can still be revoked.
            var names = (_orchestrator.Latest.GetValueOrDefault(ProviderKind.Codex)?.Accounts
                    .Select(a => a.Label) ?? Enumerable.Empty<string>())
                .Concat(new CodexAccountPool().ListAccounts().Select(a => a.Email ?? a.Label))
                .Concat(_settings.CodexWatchSharedEmails)
                .Where(WatchAccount.IsValidAccountName).Select(WatchAccount.Normalize)
                .Distinct().OrderBy(x => x).ToArray();
            var signature = string.Join("\n", names);
            if (signature == accountSignature) return;
            accountSignature = signature;
            accounts.SuspendLayout();
            while (accounts.Controls.Count > 0) accounts.Controls[0].Dispose();
            if (names.Length == 0)
                accounts.Controls.Add(WatchLabel("尚未获取本机 Codex 账号。请点击下方刷新重试；这不一定表示未登录。"));
            foreach (var email in names)
            {
                var check = new CheckBox
                {
                    Text = email, AutoSize = true,
                    Checked = _settings.CodexWatchSharedEmails.Any(x => WatchAccount.Normalize(x) == email),
                };
                check.CheckedChanged += (_, _) =>
                {
                    _settings.CodexWatchSharedEmails = _settings.CodexWatchSharedEmails
                        .Where(x => WatchAccount.Normalize(x) != email)
                        .Concat(check.Checked ? new[] { email } : Array.Empty<string>()).ToList();
                    SaveWatch();
                };
                accounts.Controls.Add(check);
            }
            accounts.ResumeLayout(true);
        }
        sharing.CheckedChanged += (_, _) =>
        {
            _settings.CodexWatchSharingEnabled = sharing.Checked;
            accounts.Enabled = sharing.Checked;
            SaveWatch();
        };
        accounts.Enabled = sharing.Checked;
        UpdateAccounts();

        section.Controls.Add(WatchLabel("我关注的账号（对方需要先分享对应邮箱）"));
        var input = new TextBox { PlaceholderText = "对方 Codex 账号的邮箱", Dock = DockStyle.Fill };
        section.Controls.Add(input);
        var error = WatchLabel("");
        error.ForeColor = Color.Firebrick;
        section.Controls.Add(error);
        var buttons = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Top, WrapContents = true };
        var add = new Button { Text = "添加关注", AutoSize = true, Enabled = false };
        var refresh = new Button { Text = "刷新账号和关注状态", AutoSize = true };
        buttons.Controls.Add(add);
        buttons.Controls.Add(refresh);
        section.Controls.Add(buttons);
        var watched = WatchLayout();
        section.Controls.Add(watched);
        var statusLabels = new Dictionary<string, Label>();

        void RebuildWatched()
        {
            watched.SuspendLayout();
            while (watched.Controls.Count > 0) watched.Controls[0].Dispose();
            statusLabels.Clear();
            foreach (var email in _settings.CodexWatchWatchedEmails.Select(WatchAccount.Normalize).Distinct().ToArray())
            {
                var row = WatchLayout();
                var label = WatchLabel(email);
                statusLabels[email] = label;
                row.Controls.Add(label);
                var remove = new Button { Text = "移除关注", AutoSize = true };
                remove.Click += (_, _) =>
                {
                    _settings.CodexWatchWatchedEmails = _settings.CodexWatchWatchedEmails
                        .Where(x => WatchAccount.Normalize(x) != email).ToList();
                    SaveWatch();
                    RebuildWatched();
                };
                row.Controls.Add(remove);
                watched.Controls.Add(row);
            }
            if (statusLabels.Count == 0) watched.Controls.Add(WatchLabel("还没有关注任何账号。"));
            watched.ResumeLayout(true);
        }
        void UpdateStatuses()
        {
            reads.Text = string.Join("\n", _settings.CodexWatchSharedEmails.Select(email =>
            {
                var count = _hostState().WatchReadCounts.GetValueOrDefault(WatchAccount.Normalize(email));
                return count is { ReadCount: > 0 }
                    ? $"{email} · 被查看 {count.ReadCount} 次 · 最近 {count.LastReadAt?.ToLocalTime():g}"
                    : $"{email} · 还没有读取记录";
            }));
            var rows = _hostState().WatchedRows;
            foreach (var (email, label) in statusLabels)
            {
                var row = rows.FirstOrDefault(r => r.Email == email);
                var status = row?.StatusText switch
                {
                    "available" => $"云端 · {row.QuotaSummary ?? $"{row.WindowName}: {row.RemainingPercent}% 剩余"} · 更新于 {row.PublishedAt?.ToLocalTime():g}",
                    "not shared" => "对方尚未分享此邮箱，请对方在分享设置中勾选。",
                    "stale" => "对方很久未上报，请确认对方的应用仍在运行。",
                    "unreachable" => "暂时无法获取，请检查网络后刷新。",
                    _ => "正在获取…",
                };
                label.Text = email + "\n" + status;
            }
        }
        void AddWatched()
        {
            var email = WatchAccount.Normalize(input.Text);
            if (!WatchAccount.IsValidAccountName(email))
            {
                error.Text = "请输入完整的邮箱地址。";
                return;
            }
            if (_settings.CodexWatchWatchedEmails.Any(x => WatchAccount.Normalize(x) == email))
            {
                error.Text = "这个邮箱已在关注列表中。";
                return;
            }
            _settings.CodexWatchWatchedEmails = _settings.CodexWatchWatchedEmails.Append(email).ToList();
            SaveWatch();
            input.Clear();
            RebuildWatched();
            UpdateStatuses();
        }
        input.TextChanged += (_, _) => { error.Text = ""; add.Enabled = !string.IsNullOrWhiteSpace(input.Text); };
        input.KeyDown += (_, e) =>
        {
            if (e.KeyCode != Keys.Enter) return;
            e.SuppressKeyPress = true;
            AddWatched();
        };
        add.Click += (_, _) => AddWatched();
        refresh.Click += async (_, _) =>
        {
            refresh.Enabled = false;
            try
            {
                _refreshWatch();
                await _orchestrator.RefreshAsync(CancellationToken.None);
                if (!section.IsDisposed) UpdateAccounts();
            }
            catch (Exception ex) { if (!error.IsDisposed) error.Text = "刷新失败：" + ex.Message; }
            finally { if (!refresh.IsDisposed) refresh.Enabled = true; }
        };
        RebuildWatched();
        UpdateStatuses();
        var timer = new System.Windows.Forms.Timer { Interval = 2000 };
        timer.Tick += (_, _) => { UpdateAccounts(); UpdateStatuses(); };
        section.Disposed += (_, _) => timer.Dispose();
        timer.Start();
        return section;
    }

    private static TableLayoutPanel WatchLayout()
    {
        var panel = new TableLayoutPanel
        {
            ColumnCount = 1, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Dock = DockStyle.Top, Margin = new Padding(0, 8, 0, 8),
        };
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        return panel;
    }

    private static Label WatchLabel(string text) => new()
    {
        Text = text, AutoSize = true, Dock = DockStyle.Fill, Margin = new Padding(0, 4, 0, 8),
    };
}
