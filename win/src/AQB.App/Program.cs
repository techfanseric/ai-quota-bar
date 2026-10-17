using AQB.Settings;

namespace AQB.App;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();

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
}
