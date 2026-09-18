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

## Deploy


1. Install and sign in to Wrangler.

```bash
npm install -g wrangler
wrangler login
```

2. Create a free D1 database.

```bash
wrangler d1 create ai-quota-bar
```

3. Copy `wrangler.toml.example` to `wrangler.toml`, then fill the D1 binding's
   `database_id`. For the optional D1 usage meter, also fill `CF_ACCOUNT_ID` and
   `D1_DATABASE_ID` under `[vars]` and create a read-only Account Analytics token:

```bash
wrangler secret put CF_API_TOKEN
```

4. Apply the schema.

```bash
wrangler d1 execute ai-quota-bar --file=./schema.sql
```

5. Create a long random token and store it as a Worker secret.

```bash
openssl rand -hex 32
wrangler secret put SYNC_TOKEN
```

6. Deploy.

```bash
wrangler deploy
```

7. For a development build, update `CloudSyncSettings` with the deployed Worker
   URL and token, then rebuild AI Quota Bar.

Do not commit production tokens or a populated `wrangler.toml`.

## API

- `GET /v1/health`: checks authentication and Worker availability.
- `GET /v1/app-update`: public update manifest backed by the latest GitHub release.
- `GET /v1/d1-usage`: returns account and database D1 usage when the optional Cloudflare analytics credentials are configured.
- `POST /v1/quota-samples`: stores one refresh snapshot.
- `GET /v1/quota-samples?device_id=...&limit=100`: returns the latest sample per model for inspection.
- `GET /v1/quota-samples?history=1&limit=500`: returns refresh-history samples for chart reconstruction.
- `GET /v1/account-summaries?limit=500`: summarizes retained data by provider and account for the settings data manager.
- `GET /v1/devices`: lists synchronized devices.
- `DELETE /v1/data?device_id=...`: deletes one device's synchronized data.
- `DELETE /v1/data?provider=...&account_name=...`: deletes one provider/account group across devices.
- `POST /v1/team/create`: self-service team creation (rate-limited); returns the team ID, invite code and login password exactly once.
- `POST /v1/team/login` / `POST /v1/team/logout` / `GET /v1/team/overview` / `POST /v1/team/invite/rotate` / `POST /v1/team/devices/revoke`: team dashboard session and management.
- `POST /v1/usage/join`: joins a team with an invite code, member name and device ID; returns a one-time device token.
- `POST /v1/usage/member/passphrase`: device-authenticated member passphrase for multi-Mac name reuse.
- `POST /v1/feedback`: submits feedback for the public wall. Same-origin browser requests (the `/feedback` page) and native app requests with `Authorization: Bearer <SYNC_TOKEN>` (the About tab) are accepted; 5 submissions per IP per hour.
- `GET /v1/feedback?limit=20&offset=0`: public quick-fetch API returning published feedback only. Contact info is stored for the operator but never returned here:

  ```bash
  curl -s https://ai-quota-bar.pages.dev/v1/feedback?limit=20
  ```

- `GET /v1/admin/feedback` / `POST /v1/admin/feedback/status` / `DELETE /v1/admin/feedback?id=...`: operator-console moderation (list with contact, hide/restore, delete), behind the existing admin session.

`/v1/app-update` is public. Every sync, inspection, usage, and deletion endpoint
requires `Authorization: Bearer <SYNC_TOKEN>` (usage endpoints use per-device
credentials instead). Self-service team endpoints additionally require the
`USAGE_TEAMS_ENABLED = "true"` var and the `0005_team_selfservice.sql`
migration; see `docs/codex-local-usage.md` for the full flow. Feedback needs the
`0006_feedback.sql` migration:

```bash
npx wrangler d1 execute ai-quota-bar --remote --file=migrations/0006_feedback.sql
```

## D1 read-cost safeguards

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
