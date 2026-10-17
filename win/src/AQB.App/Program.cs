using AQB.Settings;

namespace AQB.App;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();

        var screenshot = ParseOption(args, "--screenshot-control-center");
        if (screenshot is not null)
        {
            ScreenshotControlCenter(screenshot);
            return;
        }

        var settings = AppSettings.Load();
        using var vault = new CredentialVault();
        var adapters = new IProviderAdapter[]
        {
            new CodexProviderAdapter(vault),
            new KimiProviderAdapter(vault),
            new GlmProviderAdapter(vault),
            new MiniMaxProviderAdapter(vault),
        };
        using var orchestrator = new QuotaOrchestrator(settings, adapters);
        using var background = new BackgroundServices(settings, vault, orchestrator);
        background.Start();
        using var followApps = new FollowRunningAppsService(settings.FollowRunningApps);
        followApps.VisibilityChanged += () => background.SetFollowVisibility(followApps.VisibleProviders);
        background.SetFollowVisibility(followApps.VisibleProviders);

        Application.Run(new TrayHost(settings, vault, orchestrator, followApps, background));
    }

    /// <summary>Self-check mode: compose the real control center with live data and render it to a PNG.</summary>
    private static void ScreenshotControlCenter(string path)
    {
        var settings = AppSettings.Load();
        using var vault = new CredentialVault();
        var adapters = new IProviderAdapter[]
        {
            new CodexProviderAdapter(vault),
            new KimiProviderAdapter(vault),
            new GlmProviderAdapter(vault),
            new MiniMaxProviderAdapter(vault),
        };
        using var orchestrator = new QuotaOrchestrator(settings, adapters);
        using var background = new BackgroundServices(settings, vault, orchestrator);
        background.Start();
        _ = orchestrator.RefreshAsync(CancellationToken.None).ContinueWith(_ => { });

        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(15);
        while (DateTime.UtcNow < deadline && orchestrator.Latest.Count == 0)
        {
            Thread.Sleep(200);
        }

        // Wait a bit longer for the async Clash route lookup so the status card is complete.
        var routeDeadline = DateTime.UtcNow + TimeSpan.FromSeconds(8);
        while (DateTime.UtcNow < routeDeadline && background.State.Route.Group is null)
        {
            Thread.Sleep(200);
        }

        Thread.Sleep(1500); // let the first layout settle
        ControlCenterForm? form = null;
        form = new ControlCenterForm(
            orchestrator,
            () => { },
            () => { },
            () => { },
            () => background.State);
        var capture = new System.Windows.Forms.Timer { Interval = 900 };
        capture.Tick += (_, _) =>
        {
            capture.Stop();
            using var bitmap = new Bitmap(form.Width, form.Height);
            form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, form.Size));
            bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png);

            // Deterministic layout audit: every control must stay inside its parent's client area.
            var violations = new List<string>();
            AuditLayout(form, "form", violations);
            Console.WriteLine("LAYOUT-AUDIT: " + (violations.Count == 0 ? "OK (no out-of-bounds controls)" : string.Join("; ", violations)));
            DumpHeaderGeometry(form);
            DumpChartWindows(form);
            form.Close();
        };
        form.Shown += (_, _) => capture.Start();
        form.SuppressAutoClose = true;
        Application.Run(form);
    }

    private static void AuditLayout(Control parent, string path, List<string> violations)
    {
        foreach (Control control in parent.Controls)        {
            // Horizontal overflow is always a bug; vertical overflow is fine inside the
            // scrollable flow (its content is taller than the viewport by design).
            var horizontalOverflow = control.Right > parent.ClientSize.Width;
            var verticalOverflow = control.Bottom > parent.ClientSize.Height && parent is not FlowLayoutPanel;
            if (horizontalOverflow || verticalOverflow)
            {
                violations.Add($"{path}/{control.Name ?? control.GetType().Name} at ({control.Left},{control.Top}) size {control.Width}x{control.Height} exceeds {parent.ClientSize.Width}x{parent.ClientSize.Height}");
            }

            AuditLayout(control, path + "/" + (control.Name ?? control.GetType().Name), violations);
        }
    }

    /// <summary>Screenshot-mode ground truth: prints every chart's cycle window and
    /// in-window sample count so axis semantics can be verified without OCR.</summary>
    private static void DumpHeaderGeometry(Control form)
    {
        foreach (Control control in form.Controls)
        {
            if (control is not FlowLayoutPanel flow)
            {
                continue;
            }

            foreach (Control card in flow.Controls)
            {
                if (!card.Controls.OfType<IconButton>().Any())
                {
                    continue;
                }

                foreach (Control child in card.Controls)
                {
                    if (child is IconButton button)
                    {
                        Console.WriteLine($"HEADER-GEO card={card.Height}px button={button.Height}px top={button.Top}px bottomGap={card.Height - button.Bottom}px");
                    }
                    else
                    {
                        var text = child.Text is { Length: > 24 } t ? t[..24] + "…" : child.Text;
                        Console.WriteLine($"HEADER-GEO child={child.GetType().Name} \"{text}\" top={child.Top}px h={child.Height}px");
                    }
                }

                return;
            }
        }
    }

    private static void DumpChartWindows(Control parent)
    {
        foreach (Control control in parent.Controls)
        {
            if (control is QuotaAreaChart chart)
            {
                var inWindow = chart.Points.Count(p => p.AtUtc >= chart.WindowStart && p.AtUtc <= chart.WindowEnd);
                Console.WriteLine(
                    $"CHART window {chart.WindowStart.ToLocalTime():MM-dd HH:mm} → {chart.WindowEnd.ToLocalTime():MM-dd HH:mm}" +
                    $" pace={(chart.PaceIsReserve is { } r ? (r ? "reserve" : "deficit") : "none")}" +
                    $" samples={chart.Points.Count} inWindow={inWindow}");
            }

            DumpChartWindows(control);
        }
    }

    private static string? ParseOption(string[] args, string name)
    {
        for (var i = 0; i < args.Length; i++)
        {
            if (string.Equals(args[i], name, StringComparison.OrdinalIgnoreCase))
            {
                return i + 1 < args.Length ? args[i + 1] : name + ".png";
            }
        }

        return null;
    }
}
