# Display hot-plug refresh and companion-app termination guard · local delivery checklist

- Public-impact assessment: the macOS display list in Settings → General now
  rebuilds itself when a screen is attached or detached, instead of waiting for
  a manual "Refresh readings" click. A display whose EDID carries no product
  name still shows a generic "Display N" label; that name comes from the
  monitor firmware and cannot be synthesised.
- Destructive-operation assessment: ending or launching a companion app
  (ChatGPT/Codex) is now an explicitly injected capability. The production
  singleton opts in to the real implementation; every other construction site
  (unit tests, SwiftUI previews, render harnesses) receives an inert default,
  so a test run can no longer close a window the user is working in. The
  account-switch "automatic" mode keeps its user-visible behaviour: when the
  user asks to switch accounts, the app still quits and relaunches the desktop
  client on purpose.
- Version/download assessment: Mac stable remains 1.39.3 (86), Windows
  prerelease remains 1.38.6-beta.1. Public downloads, update metadata and
  published release history are unchanged. No tag, public release, push or
  production website deployment is part of this local implementation;
  deployment IDs and public artifact checksums are not applicable.
- Root cause of the earlier incident: `CodexAuthAccountStore` took the
  app-terminating implementation as a defaulted constructor parameter, so
  every store that did not override it inherited the live
  `NSRunningApplication.terminate()` path. A render test that reported a
  running desktop app and selected the automatic exit mode therefore quit the
  real ChatGPT client, repeatedly, once per test run.
- Verification: the complete suite finished with **802 tests, 4 skipped and 2
  failures**, both in the pre-existing
  `CodexSleepProtectionCoordinatorTests.testTurnEndGraceKeepsProtectionUntilGraceExpires`
  case, which is timing-sensitive under full-suite load and passes reliably
  when run alone (0.538 s, exit 0). No failure involves the display-list
  refresh or the account-switch termination guard. The account-switch selection
  (`CodexAuthAccountStoreTests`, `CodexAccountSwitchPopoverRenderTests`,
  `CodexAuthMirrorTests`) finished with **37 tests, 0 failures**. A new
  regression test asserts that a store without an explicit auto-quit
  implementation leaves the switch request pending instead of acting.
- Regression coverage: `DisplayTopologyMonitor` is injected into
  `StepAwayDimController`; a new test asserts the display list rebuilds after a
  topology change without a manual refresh.
- Test-run isolation: the suite was executed detached from the interactive
  session so that an interrupted run cannot leave a test process alive. The
  repository working rules now require this and forbid wiring a live
  terminating implementation into a store that reports a companion app as
  running.
- Website update not required yet: the change is confined to macOS behaviour
  that is not described on the public home pages, downloads, FAQ or platform
  matrix, and the wording that does exist for the brightness section does not
  describe display-list refresh timing. The bilingual release notes for this
  delivery are recorded under this folder and are synchronized with the next
  published release.
- Local build/install: not performed in this delivery. The working tree also
  contains earlier authorized quota/model-activity work that is not part of
  these changes.
