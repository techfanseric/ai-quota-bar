Published as part of [v1.39.1](v1.39.1.en.md). The text below records the earlier local-development stage.

# Menu account masking (unreleased, macOS only)

- Adds **Settings → General → Account display → Mask accounts in menus**, off by default. The choice is saved and applies immediately.
- Masks account names and emails in the left quota menu and right Codex account list. For example, `abcdefg@example.com` becomes `a****g@example.com`. Single-character names are fully hidden; two-character names retain only the first character. Email domains remain visible.
- Also masks external-switch details and tooltips, delete confirmations and legacy backup names. Account action messages use neutral summaries; menu renaming is paused to prevent the editor from revealing identities.
- Only changes menu presentation. Identity, login, grouping, switching, collection and sync retain raw account data. Mobile Dashboard masking is separate; settings pages are outside this switch's scope.
- Not implemented on Windows. Current Mac v1.39.0 and Windows v1.38.6-beta.1 public downloads remain unchanged; this feature is packaged as local test build 1.39.0 (83) and has not been publicly released.
