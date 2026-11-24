Published as v1.39.6 on 2026-11-24; final delivery is tracked in
[v1.39.6](v1.39.6-checklist.md). The following records the earlier local-only
work.

# Pace in collapsed Codex account rows

- Public impact is limited to the macOS left-click Codex menu. The collapsed header shows pace for the same selected window as the remaining percentage. The estimate is shown for current windows with enough data and respects the existing cloud freshness limit.
- The bilingual home pages, FAQ, README capability matrices, usage guidance, and unreleased notes document the display. Published v1.39.5 and older release descriptions still refer to the builds they shipped with.
- The macOS stable download remains v1.39.5 and the independent Windows prerelease remains v1.38.6-beta.1. The source change adds no credentials, upload, or network request. This delivery is local.
- Pages build, release-site gate, JavaScript syntax checks, and all 143 website tests passed.
- All 50 selected Swift tests passed. Inspected offscreen masked and unmasked renders at the production menu width. The renders showed reserve, red deficit, and on-pace labels alongside percentages, with pace omitted on stale cloud rows. Long names truncated and the plan was hidden when space ran out.
- Installed the local macOS build on 2026-11-23 with `make install APP_BUILD=89` from the working tree based on `87b07e4`. `/Applications/AIQuotaBar.app` reports v1.39.5 (89) and restarted from the installed path. The signed bundle passed strict verification. The built and installed executable SHA-256 both matched `2f85bd541bdbb9ab7c46205073ce05c64d9180502f7c59e620988f69a3f4d792`.
