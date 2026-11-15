# Unreleased · Display hot-plug refresh and companion-app termination guard (macOS)

**Settings → General → Dim** now notices a display being plugged in or
unplugged and rebuilds the screen list on its own, so a newly connected monitor
no longer waits for a manual "Refresh readings" click. A monitor whose EDID
carries no product name still appears as a generic "Display N"; that label
comes from the monitor firmware and cannot be invented locally.

Ending or launching ChatGPT/Codex is now an explicitly injected capability.
Only the production app instance is allowed to quit or relaunch the desktop
client; tests, previews and render harnesses receive an inert default, so
running the test suite can no longer close a ChatGPT window you are working
in. Account switching in "automatic" mode is unchanged: when you ask to
switch accounts, the app still quits and relaunches the desktop client on
purpose.

This is unreleased macOS source only. Public Mac v1.39.3 and Windows
v1.38.6-beta.1 downloads are unchanged.

[Verification checklist](unreleased-display-hotplug-checklist.md)
