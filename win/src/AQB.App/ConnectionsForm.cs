namespace AQB.App;

/// <summary>Read-only OpenAI connection monitor: counts, speeds, 60-minute age grid, list.</summary>
internal sealed class ConnectionsForm : Form
{
    private readonly IConnectionViewAdapter _adapter;
    private readonly Label _summary = new();
    private readonly Panel _grid = new();
    private readonly ListView _list = new();
    private readonly System.Windows.Forms.Timer _timer = new() { Interval = 1000 };

    public ConnectionsForm(IConnectionViewAdapter adapter)
    {
        _adapter = adapter;

        Text = "AI Quota Bar — Connections (read-only)";
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(640, 560);
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = new Font("Segoe UI", 9f);

        _summary.Location = new Point(12, 12);
        _summary.Width = 600;
        _summary.Height = 22;

        _grid.Location = new Point(12, 40);
        _grid.Size = new Size(600, 70);
        _grid.Paint += (_, e) => DrawAgeGrid(e.Graphics);

        _list.Location = new Point(12, 118);
        _list.Size = new Size(600, 380);
        _list.View = View.Details;
        _list.Columns.Add("Host", 200);
        _list.Columns.Add("Protocol", 80);
        _list.Columns.Add("Route", 140);
        _list.Columns.Add("Age", 60);
        _list.Columns.Add("Speed", 100);

        Controls.Add(_summary);
        Controls.Add(_grid);
        Controls.Add(_list);

        _timer.Tick += (_, _) => Reload();
        _timer.Start();
        Load += (_, _) =>
        {
            Reload();
            adapter.SetLive(true);
        };
        FormClosed += (_, _) =>
        {
            _timer.Stop();
            adapter.SetLive(false);
        };
    }

    private void Reload()
    {
        _summary.Text = $"OpenAI connections: {_adapter.OpenAiCount} · ↓ {FormatBps(_adapter.DownloadBps)} · ↑ {FormatBps(_adapter.UploadBps)}";

        _list.BeginUpdate();
        _list.Items.Clear();
        foreach (var connection in _adapter.Connections)
        {
            var item = new ListViewItem(connection.Host);
            item.SubItems.Add(connection.Protocol);
            item.SubItems.Add(connection.Route);
            item.SubItems.Add($"{connection.AgeMinutes:0}m");
            item.SubItems.Add(connection.SpeedText);
            item.ForeColor = AgeColor(connection.AgeMinutes);
            _list.Items.Add(item);
        }

        _list.EndUpdate();
        _grid.Invalidate();
    }

    private void DrawAgeGrid(Graphics g)
    {
        var ages = _adapter.MinuteAges;
        var cellWidth = _grid.ClientSize.Width / 60f;
        for (var i = 0; i < 60; i++)
        {
            var age = ages.Count > i ? ages[i] : null;
            var color = age is null
                ? Color.FromArgb(40, 40, 44)
                : AgeColor(age.Value);
            using var brush = new SolidBrush(color);
            g.FillRectangle(brush, i * cellWidth + 1, 8, Math.Max(2f, cellWidth - 2), _grid.ClientSize.Height - 16);
        }

        using var font = new Font("Segoe UI", 7.5f);
        using var textBrush = new SolidBrush(Color.DimGray);
        g.DrawString("-60m", font, textBrush, 0, _grid.ClientSize.Height - 14);
        g.DrawString("now", font, textBrush, _grid.ClientSize.Width - 26, _grid.ClientSize.Height - 14);
    }

    /// <summary>60-minute green→orange gradient, matching the macOS panel colors.</summary>
    private static Color AgeColor(double ageMinutes)
    {
        var t = Math.Clamp(ageMinutes / 60.0, 0, 1);
        var r = 0.20 + (1.00 - 0.20) * t;
        var g = 0.78 + (0.49 - 0.78) * t;
        var b = 0.35 + (0.05 - 0.35) * t;
        return Color.FromArgb((int)(r * 255), (int)(g * 255), (int)(b * 255));
    }

    private static string FormatBps(double bps) => bps >= 1_000_000
        ? $"{bps / 1_000_000:0.0}MB/s"
        : bps >= 1_000 ? $"{bps / 1_000:0.0}kB/s" : $"{bps:0}B/s";
}
