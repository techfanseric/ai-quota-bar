# v1.39.7 · Dim Allow raises the Accessibility request in place (macOS)

In the right-click panel, the **Step away** row already shows an orange hint
and an **Allow** button when "Restore on input" lacks Accessibility
permission. **Allow** now behaves like the lid-closed helper's **Install**
button: it raises the system Accessibility request from the menu itself, then
opens the Accessibility pane in System Settings. macOS still requires the user
to finish the grant in that pane; no app can toggle Accessibility on its own.
Pointer activity keeps restoring Dim without the permission, and the
Settings → General → Dim section is unchanged.

Included in macOS v1.39.7.

[Verification checklist](unreleased-dim-accessibility-request-checklist.md)
