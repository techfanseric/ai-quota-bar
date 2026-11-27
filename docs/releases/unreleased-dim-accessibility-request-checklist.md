# Dim Allow raises the Accessibility request in place · local delivery checklist

- Public-impact assessment: the macOS right-click panel's **Step away →
  Allow** button now raises the system Accessibility request in place before
  opening its pane, matching the lid-closed helper's **Install** button. The
  permission check itself already lived in the panel since v1.39.3; the
  Settings → General → Dim section and pointer-only restore are unchanged.
  macOS still requires the user to finish the grant in System Settings.
- Destructive-operation assessment: no companion app is quit or relaunched;
  the only external action is the system Accessibility request and the
  existing System Settings deep link, both triggered by an explicit click.
- Version/download assessment: Mac stable remains 1.39.6 (89), Windows
  prerelease remains 1.38.6-beta.1. No tag, public release, push or
  production website deployment is part of this local change; deployment IDs
  and public artifact checksums are not applicable.
- Code: `StepAwayDimController` gains an injected `accessibilityPromptRequester`
  (default `AXIsProcessTrustedWithOptions` with the prompt option, the same
  call the brightness-keys permission button uses) and
  `requestAccessibilityPermission()` replaces `openAccessibilitySettings()`.
  The popover button and its tooltip call/describe the new action.
- Regression coverage: `StepAwayDimControllerTests` asserts the permission
  action calls the prompt requester once and the settings opener once.
- Website: the bilingual home-page Dim bullet and an unreleased aside
  describe the in-place request; README pair gains an Unreleased section.
  `check:release-site`, `check`, `test` and `build:pages` results are
  recorded below.
- Verification: `swift build --build-tests` completed (only pre-existing
  warnings in unrelated test files). The detached selection
  `StepAwayDimControllerTests|CodexProtectionPopover` finished with **41 tests,
  0 failures** (40 controller tests plus the compact-protection-controls render
  test); the new permission-action test passed. From `cloudflare/`:
  `build:pages`, `check:release-site` (macOS v1.39.6 / Windows v1.38.6-beta.1),
  `check` and `npm test` (**143 pass, 0 fail**) all passed. `git diff --check`
  passed.
- Limits: the live system Accessibility dialog was not exercised in this
  session (the Mac already trusts the app, so the Allow button is not shown);
  the prompt path is covered by the injected-requester unit test only. No
  local install, app relaunch, commit, push or deployment was performed.
- Local build (prepared, not installed): `make sign` passed with the ad-hoc
  identity; `codesign --verify --deep --strict` reports `valid on disk` and
  `satisfies its Designated Requirement`. `dist/AIQuotaBar.app` is version
  **1.39.6 (89)**; its main executable SHA-256 is
  `30b903b972b12e47082ded85ecfd3249b3a35c764b974baf8552fed3ef4e798c`
  (54011504 bytes, built 18:18). The new tooltip string is present in the
  built binary and absent from the installed one. The running app
  (PID 53341, installed 16:10, SHA-256
  `ba7aaf6af2c7a5fe8a6f067572ba207634ebc495535dbe9ad7403a36826d74f7`)
  was not touched. Overwrite install (`make -o sign install`) is deferred
  until the user asks for it (see the next entry).
- Local install (authorized afterwards): `make -o sign install` exited 0 and
  replaced `/Applications/AIQuotaBar.app`; the app relaunched as PID 72442 at
  19:02:59 from the installed path, replacing PID 53341. Installed version is
  **1.39.6 (89)**; the installed main executable SHA-256 equals the signed
  build (`30b903b9…e798c`, 54011504 bytes). Installed
  `codesign --verify --deep --strict` passed, the temporary backup directory
  was removed on success, and a two-minute `log show` query for error/fault
  messages from the process returned nothing, with no new crash reports.
  Existing user settings are preserved (same bundle identifier and defaults
  domain). No commit, push, tag, public release or website deployment was
  performed; the public v1.39.6 download does not contain this change.
