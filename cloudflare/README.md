# AI Quota Bar Cloud Sync Backend

This directory contains the Cloudflare Worker and D1 schema used by AI Quota
Bar's optional cloud sync. The app uploads quota metadata and account labels,
but does not upload MiniMax or Codex provider credentials.

The current public app uses the built-in service endpoint. This backend can be
deployed independently for development; using a private deployment currently
requires changing `CloudSyncSettings` in the app source and rebuilding it.

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

3. Copy `wrangler.toml.example` to `wrangler.toml`, then paste the returned `database_id`.

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
- `POST /v1/quota-samples`: stores one refresh snapshot.
- `GET /v1/quota-samples?device_id=...&limit=100`: returns the latest sample per model for inspection.
- `GET /v1/quota-samples?history=1&limit=500`: returns refresh-history samples for chart reconstruction.

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
