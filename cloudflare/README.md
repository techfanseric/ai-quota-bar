# AI Quota Bar Cloud Sync Backend

This directory contains the Cloudflare Worker and D1 schema used by AI Quota
Bar's optional cloud sync. The app uploads quota metadata and account labels,
but does not upload Codex, Kimi, GLM, or MiniMax provider credentials.

The current public app uses the built-in service endpoint. This backend can be
deployed independently for development; using a private deployment currently
requires changing `CloudSyncSettings` in the app source and rebuilding it.

## Website (ai-quota-bar.pages.dev)

The marketing site (`public/` + `_worker.js`) is a Cloudflare Pages direct-upload
project. It lives on the `node.cyberic@gmail.com` Cloudflare account — the local
`wrangler login` usually cannot see it, so deploy with an API token and an
explicit account ID:

```bash
CLOUDFLARE_ACCOUNT_ID=d9b4ce8306afc5594afc55786c3a76e4 \
CLOUDFLARE_API_TOKEN=<token from ~/cf-fb-setup/secrets/cloudflare-api-tokens.md> \
npm run deploy:pages
```

- Project: `ai-quota-bar` → https://ai-quota-bar.pages.dev (production on `main`).
- The API token (Pages: Edit + Workers: Edit) is maintained in
  `~/cf-fb-setup/secrets/cloudflare-api-tokens.md` on this machine; never commit
  it. Re-deploy is idempotent — only changed files upload.
- `npm run build:pages` alone refreshes `dist-pages/` for a local preview
  (`/mobile-preview` and `/changelog` need the path rewrites that only the
  deployed `_worker.js` provides; `python3 -m http.server` cannot serve them).

## Deploy / upgrade for public teams

Apply `schema.sql` and migrations `0001` through `0007` in order for a new database.
For an existing installation already on `0006`, apply the additive migration **before** deploying this Worker:

```bash
npx wrangler d1 execute ai-quota-bar --remote --file=migrations/0007_team_quota.sql
npm run check
npm test
npm run build:pages
npm run deploy:pages
```

Set `USAGE_TEAMS_ENABLED=true`. Keep independent `OPS_ADMIN_SECRET` (platform console)
and `USAGE_ADMIN_TOKEN` (device provisioning) secrets. `SYNC_TOKEN` is only a public-app
ingestion gate for telemetry/feedback, never authority to read or delete team data.
D1 analytics requires `CF_API_TOKEN` with Account Analytics: Read and is exposed only in `/admin`.

This release intentionally closes the legacy shared quota APIs to old app-wide tokens.
Old clients must upgrade and create/join a team. Do not restore the old Worker as a rollback:
that would reopen shared read/delete access. Keep the additive tables and roll forward.
Legacy quota/device/settings tables are preserved and visible read-only in `/admin`;
there is no automatic account-name-based assignment of historic data to teams.
See [team rollout notes](../docs/team-isolation.md) for the release checklist.

## API and authorization

- `/v1/quota-samples`, `/v1/account-summaries`, `/v1/devices`, `/v1/health`: per-device bearer credential.
  Team/member/device scope comes from the credential; caller-supplied team IDs are ignored.
- `POST /v1/quota-samples`: uploads current-device quota metadata. History is retained for 90 days using server time.
- `GET /v1/quota-samples?history=1&limit=500`: this team's retained history; without `history=1`, one latest snapshot per provider/account/model.
- `DELETE /v1/data`: not permitted to device credentials. Team account cleanup requires the team manager session.
- `POST /v1/team/create`: rate-limited public creation; returns the team ID, invite and management password once.
- `POST /v1/usage/join`: exchanges invitation + member name (+ member passphrase for an existing member) for a device credential.
  Knowing a device ID is never sufficient to rotate its credential.
- `POST /v1/usage/leave`: revokes the authenticated device. Local data and team history remain.
- `/v1/usage/identity`, `/v1/usage/events/batch`, `/v1/usage/summary`, `/v1/usage/member/passphrase`: device-authenticated usage operations.
- `/v1/team/login`, `/logout`, `/overview`, `/invite/rotate`, `/devices/revoke`, `/members/revoke`:
  management of a single team using the separate team management cookie.
- `GET /v1/team/accounts`, `DELETE /v1/team/accounts?provider=...&account_name=...`: team-manager quota inspection/cleanup.
  Deletion always includes team + provider + account and records an audit entry. Consumption events remain separate.
- `/v1/admin/data/teams`, `/accounts?team_id=...`, `/audit`, `/legacy/accounts`, `/legacy/samples`, `/legacy/devices`:
  platform-admin session only. Team account deletion uses `DELETE /v1/admin/data/accounts` with explicit team/provider/account.
- `/v1/admin/d1-usage`: platform-admin D1 analytics. The old `/v1/d1-usage` is closed.
- `POST /v1/admin/team-session {teamID}`: platform-admin session only. Swaps the browser's
  team cookie for one signed with `OPS_ADMIN_SECRET`, which team.js accepts as a manager
  session — the `/admin` console's "Open dashboard" button uses this to enter any team
  (including device-only teams without a `usage_teams` row) without touching its password.
- `/v1/admin/feedback`: existing platform feedback moderation.
- `/v1/app-update`, `GET /v1/feedback`: public read-only content. Feedback and telemetry ingestion do not grant data access.

## Legacy D1 read-cost safeguards

The following describes the quarantined historical tables and their original migration.
Current team quota reads use the mandatory `team_quota_heads` table and team-prefixed indexes.

The Worker preserves all retained history and the existing cross-device results.
It does not reduce chart sampling frequency or shorten the user's retention:

- Cleanup uses the existing `(device_id, sampled_at)` index, once per registered
  device. With no expired rows it no longer scans the complete history.
- Global history reads at most `limit` rows per device, then merges the global
  newest `limit`. Timestamp ties keep the original API's unspecified ordering.
- Identical upload retries do not rewrite samples or device heartbeats. Genuine
  corrections use UPSERT (preserving the original `created_at`), not REPLACE.
- Optional `quota_sample_heads` stores only the latest pointers for each device,
  provider, normalized account, and model, including equal-time ties. Latest
  requests aggregate this small table instead of all historical samples.
- Account summaries still compute exact historical counts and earliest dates;
  this on-demand inspection endpoint can still scan retained history.

The device-bounded operations rely on the schema's device foreign key. Do not
disable foreign keys or import orphaned samples. Runtime work is proportional
to the number of devices; this backend targets a small personal fleet.

### Upgrade an existing deployment without a large history index

Run tests with Node 22.5+ (`npm test`; Node's SQLite module is experimental), then
use the following order. Do not enable the new read path before backfill:

1. Deploy this Worker with `LATEST_INDEX_ENABLED` absent or `"false"`:

   ```bash
   npx wrangler deploy
   ```

   It works with the old schema. When the heads table appears it immediately
   maintains bulk-delete invariants, even while latest reads remain disabled.

2. Apply the additive migration:

   ```bash
   npx wrangler d1 execute ai-quota-bar --remote --file=migrations/0001_latest_heads.sql
   ```

   It creates a small heads table/index and maintenance triggers, scans existing
   history for backfill, and writes only latest pointer rows, not an index entry
   for every historical sample. Each tied latest sample is kept. Triggers are
   installed before backfill to cover concurrent uploads. The final compact-table
   prune handles older out-of-order arrivals during that window. The migration
   is repeatable. Inspect returned `meta.rows_read` / `meta.rows_written`: the
   one-time historical read is real usage and may fail if daily quota is exhausted.
   DDL/import can briefly block the database; do not promise zero interruption.

3. Verify the small table and trigger definitions, compare old/new latest results
   once, then add this to the private `wrangler.toml` and deploy again:

   ```toml
   [vars]
   LATEST_INDEX_ENABLED = "true"
   ```

   Without the flag, latest reads still use the previous history aggregation.
   Do not repeatedly run that expensive query during verification.

For rollback, switch the flag to `"false"` and redeploy **this** Worker. Keep the
additive table/triggers. Reverting to an old REPLACE-based Worker is not the
supported rollback. Bulk API deletions first remove corresponding heads in the
same transaction, preventing a trigger from repeatedly restoring progressively
older samples during a full-group deletion. Individual SQL deletions and sample
corrections repair the affected head group; these uncommon operations can read
that group's retained history.

Index maintenance adds small writes for each newly latest sample. Exact duplicate
uploads add none. This trades a bounded number of pointer writes for removing
the repeated full-history read from every routine quota refresh. No API responses
are cached, so uploads remain immediately visible to subsequent requests.

## Product homepage

The root page is served from `public/` through the Pages ASSETS binding. `npm run build:pages` copies the static files and bundles the existing API Worker. Only the explicitly listed public assets bypass authentication; `/v1/` keeps its existing authentication and database behavior. Frontend demos use deterministic sample data, do not call APIs, and include no screenshots or external assets. Downloads link to the public GitHub release; unreleased desktop features are labelled as previews.

## 运营后台

`/admin` 提供独立管理员登录、匿名安装数、日/周/月活、90 天趋势和版本分布，以及反馈留言管理（查看含联系方式的完整内容、隐藏/恢复、删除；联系方式不会出现在任何公开 API）。配置和统计口径见 [运营后台说明](../docs/operations.md)。
