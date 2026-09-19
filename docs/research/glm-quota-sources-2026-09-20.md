# GLM quota source investigation — 2026-09-20

Status: live personal-account verification completed. The existing quota source is correct. Implemented only a verified, independent read-only reset-allowance summary. Release-mode GLM, menu presentation and curve selection regression tests: 47 passed. Accepted by the user and included in v1.22.0 (build 48).

## Evidence versions

- `~/codexbar` is a source directory without `.git`, so it cannot be pulled or prove remote freshness.
- Fetched the existing dependency repository's origin without changing its pinned checkout. Remote `main`: `0f8489dd8601495d21805dbae5cfc7e0614b124a` (2026-09-19). Examined an archive of that revision under `/tmp/glm-research-latest`.
- [Latest inspected CodexBar plugin](https://github.com/steipete/CodexBar/blob/0f8489dd8601495d21805dbae5cfc7e0614b124a/Sources/CodexBarCore/Resources/Plugins/zai.js), [provider documentation](https://github.com/steipete/CodexBar/blob/0f8489dd8601495d21805dbae5cfc7e0614b124a/docs/zai.md), [balance tests](https://github.com/steipete/CodexBar/blob/0f8489dd8601495d21805dbae5cfc7e0614b124a/TestsPlugin/ZaiPluginBalanceTests.swift), [reset tests](https://github.com/steipete/CodexBar/blob/0f8489dd8601495d21805dbae5cfc7e0614b124a/TestsPlugin/ZaiPluginResetTests.swift).
- Installed ZCode desktop 3.14.0 (3.14.0.7681), bundled CLI 0.16.9. Read installed application code; ran only `node /Applications/ZCode.app/Contents/Resources/glm/zcode.cjs --help`. No model requests, account mutations, reset redemption, or credential extraction.
- Ego-browser task space 26: user logged in and authorized continuation. Captured successful quota, monetary balance, and personal reset-list responses. Replayed the reset-list GET using only the quota Authorization, with cookies omitted: success. No credentials or private account IDs are retained in this report.

## Findings

### Coding Plan quota

Both latest CodexBar and ZCode use `GET /api/monitor/usage/quota/limit`, the same route our app already uses. Relevant fields are `limits[].type`, `unit`, `number`, `usage`, `currentValue`, `remaining`, `percentage`, and optional `nextResetTime` (milliseconds).

`CREDIT_LIMIT` / `TOKENS_LIMIT` are plan windows; `TIME_LIMIT` is MCP usage. Units: 1 = day, 3 = hour, 5 = minute, 6 = week. CodexBar special-cases legacy MCP unit 5 / number 1 as a monthly marker rather than one minute. Our app currently does not have that special case; verify the user's actual MCP response before expanding scope.

Neither inspected implementation supplies a missing five-hour reset from a better endpoint. ZCode preserves absent reset fields. The existing app's missing-reset behavior should remain unknown; its rolling five-hour chart is an observation window, not a claimed billing cycle.

Latest CodexBar also drops impossible five-hour resets beyond now + 5h + 60s, retaining quota. This is an evidence-backed robustness candidate, but no occurrence has yet been established in this account. Do not guess timezone corrections.

Our app intentionally prefers the server's `remaining` count. CodexBar takes the larger used count when usage/currentValue/remaining disagree; do not copy that rule blindly because server counts may round independently.

### Money balance and grants — separate from plan credits

Latest CodexBar adds optional CN-only `GET https://www.bigmodel.cn/api/biz/account/query-customer-account-report`.

- `availableBalance`: preferred available monetary balance.
- `balance`: fallback monetary balance when available balance is absent.
- `giveAmount`: grant amount shown as monetary provenance, **not proven to be unspent grant balance**.
- `rechargeAmount`, `totalSpendAmount`, `frozenBalance`: additional account fields in upstream fixtures.

Upstream comments claim live verification and raw/Bearer API-key compatibility. The live web-account response confirms these fields, including that cumulative grants can coexist with zero available balance. API-key authentication for this separate monetary endpoint was not independently tested. A failed optional request must not fail or delay quota display. Never add RMB values to Coding Plan credit percentages, and never label `giveAmount` as remaining gifted quota without separate evidence.

### ZCode CLI and other quota classes

The bundled CLI has `app-server`, `doctor`, `login`, `plugins`, `skills`, and TUI commands. Its help exposes no standalone usage/quota command. Launching an agent prompt to obtain quota would be unnecessary and could spend quota.

The desktop contains:

- `GET /api/v1/coding-plan/reset/status`: available five-hour/weekly reset items (`expire_at`), latest reset history (`used_at`), unread status. Requires ZCode auth plus BigModel account auth. This is a reset entitlement, not a balance. Do not call mutation routes `/use`, `/opportunity`, or `/history/read` for read-only investigation.
- `GET /api/v1/zcode-plan/billing/balance`: Start Plan-specific balances with plan/bucket/entitlement identities, units, remaining/available/reserved amounts, period boundaries and expiry. The code routes by explicit Start Plan identity. It is not evidence that a Coding Plan account's promotional quota lives here.
- `/api/monitor/credit-usage/activity` and `/usage-detail`: historical credit analytics. They are not a substitute for authoritative remaining quota or reset metadata.

## Decision boundary

Keep current implementation until live data identifies a useful addition or an actual incorrect mapping. Resolve what “gifted quota” means: monetary grants, token trial packages, reset entitlements, or separate ZCode plan benefits. The verified useful addition is `GET https://bigmodel.cn/api/biz/customer-package-reset/list?targetType=PERSONAL`: `fiveHourResets[]` and `weekResets[]`, each with an authoritative `available` flag and `expireTime`. Expired/unavailable entries must not be counted. Reuse only verified same-host personal web credentials; other hosts and team scopes skip the optional lookup. The app keeps this information independent of quota values and makes no reset mutation calls. Test, reinstall and restart for acceptance before releasing.
