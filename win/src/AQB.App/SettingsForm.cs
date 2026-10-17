using AQB.Settings;

namespace AQB.App;

/// <summary>Settings window with the six tabs of the macOS app (Windows-applicable subset).</summary>
internal sealed class SettingsForm : Form
{
    private readonly AppSettings _settings;
    private readonly CredentialVault _vault;
    private readonly Action _applyChanges;

    public SettingsForm(AppSettings settings, CredentialVault vault, Action applyChanges)
    {
        _settings = settings;
        _vault = vault;
        _applyChanges = applyChanges;

        Text = "AI Quota Bar — Settings";
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(560, 520);
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = new Font("Segoe UI", 9f);

        var tabs = new TabControl { Dock = DockStyle.Fill };
        tabs.TabPages.Add(BuildGeneralTab());
        tabs.TabPages.Add(BuildProvidersTab());
        tabs.TabPages.Add(BuildClashTab());
        tabs.TabPages.Add(BuildPowerTab());
        tabs.TabPages.Add(BuildDashboardTab());
        tabs.TabPages.Add(BuildTeamTab());

        var footer = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom,
            FlowDirection = FlowDirection.RightToLeft,
            Height = 44,
            BackColor = SystemColors.Control,
        };
        var save = new Button { Text = "Save", Width = 90, DialogResult = DialogResult.OK };
        save.Click += (_, _) => SaveAll();
        var cancel = new Button { Text = "Cancel", Width = 80, DialogResult = DialogResult.Cancel };
        footer.Controls.Add(save);
        footer.Controls.Add(cancel);
        AcceptButton = save;
        CancelButton = cancel;

        Controls.Add(tabs);
        Controls.Add(footer);
    }

    private TabPage BuildGeneralTab()
    {
        var page = MakeTab("General");
        var y = 16;
        AddCombo(page, ref y, "Menu bar appearance", new[] { "detailedText", "compactRing" }, _settings.MenuBarAppearance, v => _settings.MenuBarAppearance = v);
        AddNumber(page, ref y, "Refresh interval (seconds, min 30)", _settings.UsageRefreshIntervalSeconds, v => _settings.UsageRefreshIntervalSeconds = Math.Max(30, v));
        AddCheck(page, ref y, "Follow running apps (hide providers whose desktop app is closed)", _settings.FollowRunningApps, v => _settings.FollowRunningApps = v);
        AddCheck(page, ref y, "Check for updates automatically (daily, discreet)", _settings.AppUpdateCheckEnabled, v => _settings.AppUpdateCheckEnabled = v);
        AddLabel(page, ref y, "Share & watch Codex quota by email (CodexWatch):");
        AddCheck(page, ref y, "Share my quota for the emails listed below", _settings.CodexWatchSharingEnabled, v => _settings.CodexWatchSharingEnabled = v);
        AddMultiLine(page, ref y, "Shared emails (one per line)", string.Join("\n", _settings.CodexWatchSharedEmails), text =>
            _settings.CodexWatchSharedEmails = SplitLines(text).Where(AQB.Team.WatchAccount.IsValidAccountName).ToList());
        AddMultiLine(page, ref y, "Watched emails (one per line)", string.Join("\n", _settings.CodexWatchWatchedEmails), text =>
            _settings.CodexWatchWatchedEmails = SplitLines(text).Where(AQB.Team.WatchAccount.IsValidAccountName).ToList());
        AddLabel(page, ref y, "Provider order: " + string.Join(" › ", _settings.CustomProviderOrder.ToArray()));
        var orderBox = new TextBox
        {
            Text = string.Join(",", _settings.CustomProviderOrder),
            Location = new Point(24, y),
            Width = 420,
        };
        y += 30;
        orderBox.Leave += (_, _) =>
        {
            var parsed = orderBox.Text
                .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(s => s.Trim().ToLowerInvariant())
                .Where(s => s is "codex" or "kimi" or "glm" or "minimax")
                .Distinct()
                .ToList();
            foreach (var fallback in new[] { "codex", "kimi", "glm", "minimax" })
            {
                if (!parsed.Contains(fallback))
                {
                    parsed.Add(fallback);
                }
            }

            _settings.CustomProviderOrder = parsed;
            orderBox.Text = string.Join(",", parsed);
        };
        page.Controls.Add(orderBox);
        return page;
    }

    private TabPage BuildProvidersTab()
    {
        var page = MakeTab("Providers");
        var y = 16;
        AddCheck(page, ref y, "Monitor Codex (local credentials, no key needed)", !_settings.PausedUsageProviders.Contains("codex"), v => TogglePaused("codex", !v));
        AddCredential(page, ref y, "Kimi API key (optional — desktop session is picked up automatically)", "kimi.apiKey");
        AddCheck(page, ref y, "Monitor Kimi", !_settings.PausedUsageProviders.Contains("kimi"), v => TogglePaused("kimi", !v));
        AddCredential(page, ref y, "GLM Coding Plan API key", "glm.apiKey");
        AddCredential(page, ref y, "GLM web session (paste copied cURL here)", "glm.importedCurl", multiline: true);
        AddCheck(page, ref y, "Monitor GLM", !_settings.PausedUsageProviders.Contains("glm"), v => TogglePaused("glm", !v));
        AddCredential(page, ref y, "MiniMax coding-plan token", "minimax.token");
        AddCheck(page, ref y, "Monitor MiniMax", !_settings.PausedUsageProviders.Contains("minimax"), v => TogglePaused("minimax", !v));
        return page;
    }

    private TabPage BuildClashTab()
    {
        var page = MakeTab("Clash");
        var y = 16;
        AddLabel(page, ref y, "Route filter (country like 日本 / JP / 🇯🇵, or regex)");
        var filter = new TextBox
        {
            Text = _settings.ClashRouteFilterText,
            Location = new Point(24, y),
            Width = 420,
        };
        y += 30;
        filter.Leave += (_, _) => _settings.ClashRouteFilterText = filter.Text.Trim();
        page.Controls.Add(filter);
        AddCheck(page, ref y, "Treat filter as regular expression", _settings.ClashAutoRecoveryUseRegex, v => _settings.ClashAutoRecoveryUseRegex = v);
        AddCheck(page, ref y, "Automatic recovery (switch to fastest matching route when openai.com and chatgpt.com both fail twice)", _settings.ClashAutoRecoveryEnabled, v => _settings.ClashAutoRecoveryEnabled = v);
        return page;
    }

    private TabPage BuildPowerTab()
    {
        var page = MakeTab("Power");
        var y = 16;
        AddLabel(page, ref y, "Keep the machine awake only while AI tasks are actually working.");
        AddCheck(page, ref y, "Enable sleep protection", _settings.CodexSleepProtectionEnabled, v => _settings.CodexSleepProtectionEnabled = v);
        AddCheck(page, ref y, "Keep display awake", _settings.CodexSleepProtectionKeepDisplayAwake, v => _settings.CodexSleepProtectionKeepDisplayAwake = v);
        AddCheck(page, ref y, "Prevent screen saver", _settings.CodexSleepProtectionPreventScreenSaver, v => _settings.CodexSleepProtectionPreventScreenSaver = v);
        AddCheck(page, ref y, "Allow closed-lid mode (changes lid-close action via powercfg, restores afterwards)", _settings.CodexSleepProtectionAllowClosedLid, v => _settings.CodexSleepProtectionAllowClosedLid = v);
        return page;
    }

    private TabPage BuildDashboardTab()
    {
        var page = MakeTab("Mobile Dashboard");
        var y = 16;
        AddLabel(page, ref y, "Read-only local dashboard for phones on the same network (port 18765).");
        AddCheck(page, ref y, "Enable mobile dashboard", _settings.MobileDashboardEnabled, v => _settings.MobileDashboardEnabled = v);
        AddNumber(page, ref y, "Port", _settings.MobileDashboardPort, v => _settings.MobileDashboardPort = v);
        AddCheck(page, ref y, "Require pairing code", _settings.MobileDashboardRequiresPairingCode, v => _settings.MobileDashboardRequiresPairingCode = v);
        AddCheck(page, ref y, "Mask account names", _settings.MobileDashboardMaskAccountNames, v => _settings.MobileDashboardMaskAccountNames = v);
        return page;
    }

    private TabPage BuildTeamTab()
    {
        var page = MakeTab("Usage & Team");
        var y = 16;
        AddLabel(page, ref y, "Team usage sync goes through the shared Cloudflare worker (create/join in the web console).");
        AddCheck(page, ref y, "Cloud sync (upload quota metadata only, never credentials)", _settings.CloudSyncEnabled, v => _settings.CloudSyncEnabled = v);
        AddCheck(page, ref y, "Member usage reporting", _settings.LocalUsageReporting, v => _settings.LocalUsageReporting = v);
        AddLabel(page, ref y, "Team credentials are stored encrypted (DPAPI) when you join from the team dashboard.");
        return page;
    }

    private static TabPage MakeTab(string title)
    {
        var page = new TabPage(title);
        page.AutoScroll = true;
        return page;
    }

    private void TogglePaused(string provider, bool paused)
    {
        _settings.PausedUsageProviders = _settings.PausedUsageProviders
            .Where(p => !string.Equals(p, provider, StringComparison.OrdinalIgnoreCase))
            .Concat(paused ? new[] { provider } : Array.Empty<string>())
            .ToList();
    }

    private void AddCredential(TabPage page, ref int y, string label, string vaultKey, bool multiline = false)
    {
        var caption = new Label { Text = label, Location = new Point(24, y), Width = 480, ForeColor = SystemColors.ControlText };
        y += 22;
        var box = new TextBox
        {
            Location = new Point(24, y),
            Width = 420,
            UseSystemPasswordChar = !multiline,
            Multiline = multiline,
            Height = multiline ? 60 : 23,
            Text = _vault.Get(vaultKey) ?? "",
        };
        y += box.Height + 12;
        page.Controls.Add(caption);
        page.Controls.Add(box);
        _pendingCredentialWrites.Add((vaultKey, box));
    }

    private readonly List<(string key, TextBox box)> _pendingCredentialWrites = new();

    private static List<string> SplitLines(string text) => text
        .Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
        .Select(s => s.Trim())
        .Where(s => s.Length > 0)
        .Distinct(StringComparer.OrdinalIgnoreCase)
        .ToList();

    private void AddMultiLine(TabPage page, ref int y, string label, string value, Action<string> set)
    {
        var caption = new Label { Text = label, Location = new Point(24, y), Width = 480 };
        y += 22;
        var box = new TextBox
        {
            Multiline = true,
            Height = 58,
            Width = 420,
            Location = new Point(24, y),
            ScrollBars = ScrollBars.Vertical,
            Text = value,
        };
        y += box.Height + 12;
        box.Leave += (_, _) => set(box.Text);
        page.Controls.Add(caption);
        page.Controls.Add(box);
    }

    private void AddCheck(TabPage page, ref int y, string label, bool value, Action<bool> set)
    {
        var check = new CheckBox { Text = label, Location = new Point(24, y), Width = 500, Checked = value };
        y += 28;
        check.CheckedChanged += (_, _) => set(check.Checked);
        page.Controls.Add(check);
    }

    private void AddNumber(TabPage page, ref int y, string label, int value, Action<int> set)
    {
        var caption = new Label { Text = label, Location = new Point(24, y), Width = 480 };
        y += 22;
        var box = new NumericUpDown { Location = new Point(24, y), Width = 120, Minimum = 1, Maximum = 86400, Value = Math.Clamp(value, 1, 86400) };
        y += 34;
        box.ValueChanged += (_, _) => set((int)box.Value);
        page.Controls.Add(caption);
        page.Controls.Add(box);
    }

    private void AddCombo(TabPage page, ref int y, string label, string[] options, string value, Action<string> set)
    {
        var caption = new Label { Text = label, Location = new Point(24, y), Width = 480 };
        y += 22;
        var combo = new ComboBox { Location = new Point(24, y), Width = 200, DropDownStyle = ComboBoxStyle.DropDownList };
        combo.Items.AddRange(options);
        combo.SelectedIndex = Math.Max(0, Array.IndexOf(options, value));
        y += 34;
        combo.SelectedIndexChanged += (_, _) => set(combo.SelectedItem?.ToString() ?? options[0]);
        page.Controls.Add(caption);
        page.Controls.Add(combo);
    }

    private void AddLabel(TabPage page, ref int y, string text)
    {
        page.Controls.Add(new Label { Text = text, Location = new Point(24, y), Width = 500, ForeColor = SystemColors.ControlText });
        y += 26;
    }

    private void SaveAll()
    {
        foreach (var (key, box) in _pendingCredentialWrites)
        {
            var text = box.Text.Trim();
            if (text.Length == 0)
            {
                _vault.Delete(key);
            }
            else
            {
                _vault.Set(key, text);
            }
        }

        _vault.Save();
        _settings.Save();
        _applyChanges();
    }
}
