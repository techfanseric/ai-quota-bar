# Magpie quota research and macOS adaptation

As of macOS v1.39.7, discovery requires a loopback Codex provider with ID or display name Magpie. Aliases at the same endpoint are supported. Other local proxies skip Magpie discovery and use the ordinary current-account path.


Reviewed 2026-11-12 against `yetone/magpie` commit `805e5c29a33540a4e968613a0ef41682c43f423f`.

## How Magpie reads quota

Magpie reads the vendor's account allowance with saved login credentials or a plan API key. Its quota reader does not require the coding agent's desktop window to be open and does not need the Magpie gateway to serve requests. Vendor quota is separate from locally counted token usage.

| Provider | Magpie source | AI Quota Bar source and adaptation |
| --- | --- | --- |
| Codex | Saved Codex sign-in; Bearer access token and account header to `/wham/usage`. Maps primary/secondary windows, used percent and reset time. | When Codex is routed through a configured local Magpie gateway, AI Quota Bar asks Magpie for its multi-account quota report first, so Magpie keeps refresh-token ownership and its per-account cache/locks. Without a usable Magpie report, it falls back to the existing active-sign-in Auto/OAuth/CLI pipeline. Desktop-running guards are removed either way. |
| Kimi Code | Plan key to the Coding API's `/usages` endpoint. | Existing manually configured Kimi Code key already uses the direct API. Automatic desktop/web sessions use Kimi billing endpoints; CLI sign-in uses the official CLI's local `/status` command, including its credential refresh. No desktop-running gate. |
| GLM / Z.ai | Plan key to `/api/monitor/usage/quota/limit`. | Existing direct quota API retained, including supported web credentials. No desktop-running gate. |
| MiniMax | Coding Plan key to `/v1/token_plan/remains`. | Existing MiniMax website plan-token API (`/v1/api/openplatform/coding_plan/remains`) retained. This is a different credential/endpoint pair; a MiniMax API key is not interchangeable with the existing website token. No desktop-running gate. |

Magpie also has per-account caches, keeps the last successful reading when a refresh fails, orders concurrent results to avoid stale overwrites, and exposes per-card refresh. Its plan quota cache avoids repeating a read within a minute. AI Quota Bar keeps its existing refresh interval, parallel provider fetches, last successful data on failure, visible error state and reset-boundary refresh. No Magpie daemon, gateway or configuration is required.

## Codex multi-account report

Follow-up reviewed 2026-11-13 against local Magpie source commit `c1144a85042c02fc16f6adfdcf045b7cc96f25d9` and installed version 0.1.3906.

AI Quota Bar discovers only a loopback `base_url` from `~/.codex/config.toml`, disables proxies and redirects, and requests the local `GET /v1/magpie/quotas` report without a gateway key. It intentionally does **not** pass `kept=1`: Magpie may return its one-minute cache immediately and start a stale refresh in the background, while `kept=1` would never ask Magpie to update the cards. AIQuotaBar never reads Magpie's account store, access tokens, refresh tokens or cookies, and never refreshes those credentials itself.

Only local Codex subscription cards feed the Codex ring. Each account keeps its readable windows (`5 hours` and `7 days`) as detail rows. The single ring is driven by a synthetic **Codex Pool**: every account contributes its most limiting readable window, and the pool percentage is the average of those percentages. A failed account remains visible in hover details and counts as zero in the denominator, so a partial outage cannot make the pool look fuller than the account set. This percentage pool is intentionally labeled as an approximation; Magpie commonly supplies percentages rather than comparable absolute capacities across Pro and ProLite.

The menu-bar tooltip shows `Magpie · readable/total accounts`, then one line per account with its name/alias, plan, limiting window, remaining percentage and reset time. Menu account masking applies to those hover lines. If Magpie is absent, unconfigured, stopped, unreachable, returns no local Codex card, or all local Codex cards are unreadable, AI Quota Bar falls back to the original active `~/.codex` reader in the same refresh. It returns to the Magpie pool on a later successful refresh without changing user settings.

## Display behavior

On macOS, Settings → General → Menu bar → Display mode → **Always visible**, followed by **Select all**, keeps every configured and enabled provider ring visible even with all companion apps closed. This takes precedence over Settings → Display → **Follow running apps**. Following still controls left-click section collapse. Work-aware and detailed text retain their running-app visibility behavior. Paused or unselected providers stay hidden; quota failures remain errors rather than disappearing or becoming a fabricated percentage.

AI Quota Bar itself must remain running. This change does not implement menu-bar rendering after quitting AI Quota Bar. No Windows ring-setting change is included.

## Credential handling

Reuse the existing provider credential readers and refresh ownership. In particular, the bundled CodexBarCore asks the native Codex CLI to refresh a native-owned expired sign-in; it does not independently rotate a refresh token owned by another process. No new credential export, upload, Magpie-store import or model inference is introduced by this adaptation. Existing user-enabled team/Watch sharing continues to receive newly fetched quota through the existing path.

## Sources

- [Quota aggregation and report](https://github.com/yetone/magpie/blob/805e5c29a33540a4e968613a0ef41682c43f423f/internal/provider/quotas.go)
- [Codex subscription quota reader](https://github.com/yetone/magpie/blob/805e5c29a33540a4e968613a0ef41682c43f423f/internal/provider/subscription_usage.go#L1073)
- [Plan API sources and cache](https://github.com/yetone/magpie/blob/805e5c29a33540a4e968613a0ef41682c43f423f/internal/provider/planquota.go)
- [Per-card refresh and ordering](https://github.com/yetone/magpie/blob/805e5c29a33540a4e968613a0ef41682c43f423f/internal/provider/quota_refresh.go)
- [Provider/account architecture](https://github.com/yetone/magpie/blob/805e5c29a33540a4e968613a0ef41682c43f423f/docs/subsystems/providers-accounts.md)
