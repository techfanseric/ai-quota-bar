# Repository working rules

## Website and release synchronization

Before every push, assess whether the change affects a user-visible feature, behavior,
installation step, supported platform, download, version, privacy boundary or published
UI preview. Record the assessment in the commit/release work log. A website-only change
also follows the checks below. Internal changes with no public impact may explicitly
record “website update not required” with the reason.

For public-impact changes, update the relevant bilingual home pages, feature sections,
platform capability matrix, download metadata, FAQs, README/user guides and release
notes in the same delivery. Audit older descriptions of the affected feature as well as
the newest release paragraph. Do not advertise a Mac-only implementation on Windows.
Track the Mac stable version and Windows prerelease independently; Windows beta must
not replace GitHub's stable `releases/latest` or receive Mac assets.

Use the release history synchronization script after publication. Include independently
published Windows beta entries with explicit prerelease/platform labels under the
current changelog policy; never present beta as stable. Preserve localized release text.

Run `npm run check:release-site`, `npm run check`, `npm test` and `npm run build:pages`
from `cloudflare/` for applicable website deliveries. `deploy:pages` must run the
`check:release-site` gate before deployment. The gate checks the Mac stable version,
Windows project version, both home pages and downloads, changelog and Worker update
fallback. Correct inconsistent versions or platform claims before deploying.

When the user authorizes publication, deploy affected website content as part of the
same delivery. A local build, Git push or updated JSON is not proof of production
publication. Verify both production home pages, both changelogs, affected download
links and update metadata; record deployment URL/id, tag/commit, artifact checksums,
checks performed and any actual limitations in the release checklist. If deployment
fails, say exactly what remains pending and why; do not mark it done.

Do not commit credentials, local console access notes, generated artifacts or private
application data. Use existing local deployment configuration without echoing secrets.
