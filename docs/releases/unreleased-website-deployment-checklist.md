# Unreleased source — website deployment record — 2026-11-18

## Scope and website impact

- Public-impact change, but **not a release**: the macOS source adds a
  one-minute lightweight mode, Magpie-driven quota rings with one C ring per
  in-use Codex account, model-family activity lights, and quota cycle-end
  notifications. No installation step, download format, version,
  supported-platform list, privacy boundary or published UI preview changes.
- Website update required and delivered: both home pages, the platform
  capability matrix, the FAQs, the bilingual README pair and the unreleased
  notes were synchronized in commit `511fadd`. The new copy states plainly
  that the behavior is macOS-only and is **not** in the public v1.39.3
  download.
- The Mac stable version (v1.39.3) and the independent Windows prerelease
  (v1.38.6-beta.1) are unchanged. The Windows ZIP links are untouched on both
  home pages, and the beta is never presented as stable.
- Privacy boundaries unchanged: AIQuotaBar reads Magpie's public local report
  and never touches Magpie's credentials; the dim bridge is dim-only and does
  not expose Restore.

## Validation

- Full `swift test`: 836 tests executed, 4 skipped, 0 failures, exit code 0.
  The suite was run three times; an earlier failure in
  `testTurnEndGraceKeepsProtectionUntilGraceExpires` was a real bug (the
  turn-end grace timer could fire early and then never re-arm itself, so
  power protection could hold forever). It was fixed in commit `8bbaff9` by
  arming the timer for the remaining time with zero tolerance.
- From `cloudflare/`: `npm run build:pages`, `npm run check:release-site`
  (macOS v1.39.3 stable; Windows v1.38.6-beta.1 prerelease), `npm run check`
  and `npm test` (143 passed, zero failures) all passed before deployment.
- `dist-pages/index.html` and `dist-pages/en/index.html` were confirmed byte
  identical to their `public/` sources before upload.

## Deployment note

- The first `npm run deploy:pages` attempt failed with a Cloudflare
  authentication error (code 10000). The cached wrangler OAuth session
  (techfanseric@gmail.com) belongs to account `acaba0e5…`, while the Pages
  project `ai-quota-bar` lives in account `d9b4ce83…`. Resolved with the
  stored node.cyberic API token from the local deployment configuration, using
  `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN`. No secret is recorded
  here. The `CF_ACCOUNT_ID` var still in `wrangler.toml` and
  `wrangler.pages.toml` points at the correct Pages account and was left as is.

## Production verification

- Deployed Pages production: **https://b090e591.ai-quota-bar.pages.dev**
  (deployment id `b090e591`, production branch `main`, commit `511fadd`).
  Upload reported 2 files changed and 51 already uploaded; the Worker bundle
  compiled successfully.
- Production `https://ai-quota-bar.pages.dev/`, `/en/`, `/changelog` and
  `/en/changelog` each returned HTTP 200. The deployment preview URL returned
  HTTP 200 as well.
- Home page content: the new Chinese FAQ entries (轻量模式会影响额度环和流光吗、
  额度周期到期都会通知吗、流光代表任务数还是模型请求数、
  关闭 AI 客户端后还能显示全部额度环吗、多个 Codex 账号同时在用) are present
  on `/`, and the English equivalents (Does lightweight mode affect rings and
  activity lights?, Will every quota cycle notify me when it ends?, and the
  account/ring FAQs) are present on `/en/`. The unreleased-source notices
  appear in both languages.
- Changelog verification: exactly one "最新 macOS 正式版" / "Latest macOS
  stable" badge per language, attached to v1.39.3. The v1.38.6-beta.1 article
  carries the "Windows 公测版" / "Windows beta" label and never the stable
  badge. Older Windows betas are labeled the same way. The
  `check-release-site` gate passes against the built pages.
- Download metadata: `/v1/app-update` returns `version`/`tag` 1.39.3/v1.39.3
  with the stable PKG download URL (source `github-proxy`), and
  `releases/latest/download/AIQuotaBar.pkg` resolves (HTTP 200) to the
  release asset. The Windows v1.38.6-beta.1 ZIP link returns HTTP 200.
- Worker health: `/healthz` returns `{"ok":true,"service":"ai-quota-bar-sync"}`.

## Actual limitations

- The deployed pages describe **unreleased** macOS behavior. The public
  v1.39.3 download does not contain the lightweight mode, the Magpie-driven
  rings, the per-account Codex rings or the cycle-end notifications, and
  Windows has none of them. The site copy says so in both languages.
- No release was published and no tag was created for this delivery; the
  Mac stable and Windows prerelease versions are unchanged, so the update
  metadata still points at v1.39.3.
- The Windows beta is still tracked independently and is not part of GitHub's
  `releases/latest`.
