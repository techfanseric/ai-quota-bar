namespace AQB.App;

/// <summary>Right-click route panel: filtered node list, latency test, switch, history.</summary>
internal sealed class ClashPanelForm : Form
{
    private readonly IClashPanelAdapter _adapter;
    private readonly TextBox _search = new();
    private readonly CheckBox _regex = new();
    private readonly ListBox _list = new();
    private readonly Label _status = new();
    private readonly Label _history = new();
    private readonly Button _test = new();
    private readonly CheckBox _autoRecovery = new();

    public ClashPanelForm(IClashPanelAdapter adapter)
    {
        _adapter = adapter;

        Text = "AI Quota Bar — Routes";
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(480, 600);
        AutoScaleDimensions = new SizeF(96f, 96f);
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = new Font("Segoe UI", 9f);

        _search.PlaceholderText = "Country (日本 / JP / 🇯🇵) or regex…";
        _search.Location = new Point(12, 12);
        _search.Width = 330;
        _search.TextChanged += (_, _) => OnFilterChanged();

        _regex.Text = "Regex";
        _regex.Location = new Point(350, 12);
        _regex.Width = 70;
        _regex.CheckedChanged += (_, _) => OnFilterChanged();

        _test.Text = "Test latency";
        _test.Location = new Point(12, 42);
        _test.Width = 110;
        _test.Click += async (_, _) =>
        {
            _test.Enabled = false;
            try
            {
                _status.Text = "Testing…";
                await _adapter.TestGroupAsync();
                await ReloadAsync();
            }
            finally
            {
                _test.Enabled = true;
            }
        };

        _autoRecovery.Text = "Automatic recovery";
        _autoRecovery.Location = new Point(130, 44);
        _autoRecovery.Width = 180;
        _autoRecovery.Checked = _adapter.AutoRecoveryEnabled;
        _autoRecovery.CheckedChanged += (_, _) => _adapter.AutoRecoveryEnabled = _autoRecovery.Checked;

        _list.Location = new Point(12, 74);
        _list.Size = new Size(440, 360);
        _list.HorizontalScrollbar = true;
        _list.DoubleClick += async (_, _) =>
        {
            if (_list.SelectedItem is RouteNodeView node)
            {
                _status.Text = $"Switching to {node.Name}…";
                var ok = await _adapter.SwitchAsync(node.Name);
                _status.Text = ok ? $"Switched to {node.Name}" : "Switch failed";
                await ReloadAsync();
            }
        };

        _status.Location = new Point(12, 440);
        _status.Width = 440;
        _status.Height = 20;
        _status.ForeColor = Color.DimGray;

        _history.Location = new Point(12, 462);
        _history.Width = 440;
        _history.Height = 56;
        _history.ForeColor = Color.DimGray;

        Controls.Add(_search);
        Controls.Add(_regex);
        Controls.Add(_test);
        Controls.Add(_autoRecovery);
        Controls.Add(_list);
        Controls.Add(_status);
        Controls.Add(_history);

        _adapter.StateChanged += OnStateChanged;
        Load += async (_, _) => await ReloadAsync();
        FormClosed += (_, _) => _adapter.StateChanged -= OnStateChanged;
    }

    private void OnStateChanged()
    {
        if (IsHandleCreated)
        {
            BeginInvoke(() => _ = ReloadAsync());
        }
    }

    private void OnFilterChanged()
    {
        var valid = !_regex.Checked || _adapter is not null; // regex validity is enforced by the adapter
        _adapter.SetFilter(_search.Text.Trim(), _regex.Checked, valid);
        _ = ReloadAsync();
    }

    private async Task ReloadAsync()
    {
        if (IsDisposed)
        {
            return;
        }

        try
        {
            var nodes = await _adapter.GetNodesAsync();
            if (IsDisposed)
            {
                return;
            }

            _list.BeginUpdate();
            _list.Items.Clear();
            foreach (var node in nodes)
            {
                var delay = node.DelayMs is null ? "—" : node.DelayMs is 0 ? "timeout" : $"{node.DelayMs}ms";
                _list.Items.Add(node);
                var index = _list.Items.Count - 1;
                var badge = string.IsNullOrEmpty(node.Badge) ? "" : $" [{node.Badge}]";
                _list.Items[index] = $"{(node.IsSelected ? "● " : "  ")}{node.Name}{badge} — {delay}";
            }

            _list.EndUpdate();
            _status.Text = _adapter.StatusLine is { } line ? line : $"Group: {_adapter.GroupName ?? "—"} · {nodes.Count} routes{(_adapter.FilterActive ? " (filtered)" : "")}";
            _history.Text = "Recent switches:\n" + string.Join("\n", _adapter.History.Select(h => $"{h.AgeText}: {h.Group} {h.From} → {h.To}"));
            if (_adapter.History.Count == 0)
            {
                _history.Text = "Recent switches: none";
            }
        }
        catch (Exception e)
        {
            _status.Text = "Clash unavailable: " + e.Message;
        }
    }
}
