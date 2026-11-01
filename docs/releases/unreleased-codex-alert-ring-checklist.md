Publication authorized on 2026-11-01; final delivery is tracked in [v1.39.1](v1.39.1-checklist.md). The following records the earlier local-only work.

# Codex alert ring · local delivery checklist

- Scope: macOS local build only, based on b53f1ea plus the existing workspace edits. No commit, push, tag, GitHub release or production website deployment requested/performed.
- Public-impact assessment: user-visible alert rendering changes. Both README languages, reset-alert guide, bilingual unreleased notes and homepage FAQs describe the local behavior and explicitly exclude current public downloads. Historical v1.39.0 bell descriptions are retained as accurate release history. Mac stable remains 1.39.0 (82); Windows remains 1.38.6-beta.1, with reset alerts unsupported. Platform support, download URLs, update fallback, credentials and data boundaries are unchanged; no download/version metadata edits required.
- Website checks: `npm run build:pages`, `npm run check:release-site`, `npm run check`, `npm test` passed (143 tests). The gate initially requested a Pages rebuild after FAQ edits; rebuilding resolved it.
- Publication: none. Production pages/downloads were not changed; release-history synchronization is not applicable before publication.
- Rendering: persistent yellow dot at Codex initial; Codex-only yellow/normal 0.75-second frames; all displayed quota geometry preserved; quota changes invalidate frames. Reduce Motion holds yellow. Dim badge stays steady. Task waves pause during unread alerts. Codex is temporarily appended if hidden. After all alerts are read, the selected display returns.
- App tests: 45 targeted alert/ring/Dim tests passed; 9 shared quota-symbol regression tests passed (54 total, no failures). The Dim compositor test now uses actual alert ring frames rather than the removed bell helper. `git diff --check` passed.
- Release: `make sign` passed, including all three release products and strict deep signature validation (local ad-hoc signing).
- Installed via `make -o sign install` using the freshly signed bundle. `/Applications/AIQuotaBar.app` remains version 1.39.0 (82), with locally modified rendering; no new public version number is advertised.
- Restart verified: old PID 40369 replaced by PID 25202, executable path `/Applications/AIQuotaBar.app/Contents/MacOS/AIQuotaBar`. Installed bundle passes `codesign --verify --deep --strict`.
- Main executable SHA-256 (identical in signed build and installed app): `4f7ee8e517f5ff449cde6491f475609caf831cdc3cab2fbe8934db2636f2e0ad`.
- No DMG/PKG or website deployment was produced. Production URLs/IDs are not applicable to this local installation.

## Local preview follow-up

- User requested an actual test alert. Added explicit `--test-reset-alert` startup flag using the real unread and notification path. Preview messages are labeled as local tests, remain unread through feed updates, are excluded from persistence, and are removed on acknowledgement/restart. Existing real alerts are preserved.
- Public impact assessment: local preview tooling only; no public downloads/version/platform/privacy changes. Existing homepage unreleased labels remain accurate; no further website update required for this follow-up. Guide documents the startup flag.
- Follow-up validation: 18 alert-store tests passed, including preview retention across feed ingestion, exclusion from persisted archive and removal on acknowledgement. Release build and strict deep signature verification passed.
- Follow-up installed main executable SHA-256: `a0e10d80a8933e154b9862105a316e38fc016ec67fc3f2a0c97d01fb0e4804d6` (signed build and installed app match).
- Restarted installed app with `--test-reset-alert`. Runtime PID 37388 confirmed `local reset-alert preview triggered`, `reset-alert attention started; reduceMotion=0`, and `reset-alert notification submitted; unread=1`. Left the single test alert unread for user inspection.
- Native UI inspection timed out; activation and notification submission were verified through the app's runtime log, not a screenshot. No production publication performed.
