# Windows DPI and Watch fixes (unreleased)

2026-11-01. macOS stable remains v1.39.1; the published Windows ZIP remains v1.38.6-beta.1. These source changes do not publish a release or replace downloads.

The tray flyout follows the clicked display and rebuilds after window creation and DPI transitions. Account and status rows use measured heights; long account/plan labels truncate, and quota metadata wraps. Text heights use the window DPI. Old cards and the refresh timer are disposed.

Watch publishes after quota refresh as well as on its regular timer. Providers settings show actual publish success time, account count, pending/failure and revocation states; failures log HTTP/network error types. Unknown or invalid window starts are null, matching the server contract. Only selected local Codex accounts publish; credentials and watched remote accounts are not forwarded. Mac generates the eye icon from successfully fetched Watch rows: it is not a publisher field. The reported Mac icon issue still needs that installation's version, watch list and fetch status to establish its cause.

The staged source was built independently: all 545 Windows Release tests passed. After adding the timestamp edge cases, all 8 affected App tests passed again. Layout checks and screenshots cover 100%, 125%, 150%, 175%, 200% and 250%, plus repeated transitions. These use injected layout DPI, not exhaustive physical multi-monitor testing. Historical tests now query with their fixed test clock rather than the current date.

Website build, release consistency gate and syntax checks passed; all 143 website tests passed. Both homepages explicitly mark these changes as unreleased source updates. No production website deployment or new Windows ZIP is claimed. Existing unrelated site-monitoring edits remain uncommitted. Full verification notes: [Chinese work log](unreleased-windows-dpi-watch.md).
