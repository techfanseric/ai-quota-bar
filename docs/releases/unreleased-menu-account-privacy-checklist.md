Publication authorized on 2026-11-01; final delivery is tracked in [v1.39.1](v1.39.1-checklist.md). The following records the earlier local-only work.

# Menu account privacy work log — 2026-10-28

## Scope and public impact

- User-visible macOS feature and display privacy boundary: persistent, opt-in menu account masking. No Windows implementation.
- Both menus share the same `maskMenuAccountNames` preference. Raw identities remain unchanged for account actions, grouping, collection and sync. Mobile Dashboard privacy remains independent.
- Bilingual README capability matrices and privacy instructions updated. Both home pages contain explicitly unreleased feature/FAQ text; existing download metadata continues to describe Mac stable v1.39.0 and Windows prerelease v1.38.6-beta.1.
- Bilingual unreleased notes: `unreleased-menu-account-privacy.en.md` and `unreleased-menu-account-privacy.zh-CN.md`. Audited older menu account rendering and Mobile Dashboard privacy descriptions; the latter remains valid for its separate surface.
- The homepage edits were included by concurrent website work in commit `b338e90`; unrelated website changes were preserved. This task has not pushed, tagged, packaged, or deployed the application feature.

## Validation

- `swift test --filter 'MenuAccountPrivacyTests|CodexAccountSwitchPopoverRenderTests|LeftClickMenuDisplayPreferencesTests|LeftMenuCodexAccountRenderTests'`: 20 tests passed, zero failures; application and test targets compiled.
- Covers email domains, short names, Unicode/grapheme names, disabled mode, emails embedded in diagnostics and preference persistence. Existing menu visibility/order tests pass.
- Visually inspected offscreen renders of masked left menu, right account list and external-switch/status state. Names and emails are masked; existing quotas and controls remain visible. Render artifacts stay outside the repository.
- From `cloudflare/`: `npm run build:pages`, `npm run check:release-site`, `npm run check`, `npm test` passed; 143 website tests passed. The release-site gate confirms Mac v1.39.0 and Windows v1.38.6-beta.1.
- Initial release-site check requested a Pages rebuild after homepage edits; rebuilt Pages and reran successfully.
- `git diff --check` passed.

## Delivery limits

- No public version/tag or application publication requested. A local package and installation were subsequently authorized and completed as recorded below.
- Settings pages are outside the menu masking scope. Domains and the permitted first/last characters remain visible, so the mode does not provide complete anonymity.
- Account rename editors are disabled while masking is on. Account action status uses neutral summaries to cover identities no longer present in the store; disable masking to inspect full diagnostic details.
- Production deployment URL/id, asset checksums and release-history synchronization are not applicable to this local application change; this log does not certify production publication by concurrent website work.

## Authorized local package and installation

- Built with `make pkg install APP_BUILD=83`; local app version 1.39.0, build 83. Source: working tree with the menu masking changes on HEAD `8824ee5` (uncommitted feature changes included).
- Replaced `/Applications/AIQuotaBar.app` (previously 1.38.5 build 81) and relaunched it. Confirmed the active process runs the installed executable. Existing account/settings data was not removed or modified by the install procedure; masking remains opt-in.
- `codesign --verify --deep --strict --verbose=2 /Applications/AIQuotaBar.app` passed. Uses the existing ad-hoc signing flow; local PKG is unsigned.
- Local artifact: `dist/AIQuotaBar.pkg`.
- PKG SHA-256: `e2217b1c70adfffc9d61a06e81b3bb10ec1b631a187811c1a25bb9322a55de82`.
- Built and installed main executable SHA-256 both match: `eedf0d433a3f7c09fc353f2319799b103f7b90709249426446f5e63fae6bafe7`.
- Generated app, PKG and checksum files remain ignored and are not committed. This local test build does not change public downloads or certify a production release.
