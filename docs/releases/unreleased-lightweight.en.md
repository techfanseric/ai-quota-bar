# Released in v1.39.4 · One-minute lightweight mode (macOS)

**Settings → General → System → Lightweight mode** is on by default. Native menus, settings and warning windows release their rebuildable presentation resources after staying closed for one minute. Reopening within the minute cancels reclamation. Hidden menus also load on demand rather than at startup.

Menu-bar rings keep their quota, trend, live model lights, hover details and alerts. Quota refresh, task protection, Dim, sync, reporting and the LAN dashboard continue. Visible, minimized and sheet-owning windows are protected.

Saved settings, accounts and history remain. The settings tab and valid window placement survive rebuilding; unsaved temporary input may be cleared. Reopening takes reconstruction time; turn the option off for frequent access. Memory savings depend on visited pages and system caches, with no fixed MB promise.

Released in [v1.39.4](v1.39.4.en.md). Windows has not received this mode.

[Magpie / Clash Verge research, implementation and limits](../research/lightweight-mode-2026-11-12.md) · [Verification checklist](unreleased-lightweight-checklist.md)
