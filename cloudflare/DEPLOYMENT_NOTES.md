# D1 read-cost optimization — 2026-09-02

## Production sequence

1. Deployed the compatible UPSERT Worker with `LATEST_INDEX_ENABLED=false`.
2. Applied `migrations/0001_latest_heads.sql` remotely: all 7 statements succeeded.
   Cloudflare reported **79,313 rows read, 85 rows written**, SQL duration about
   341 ms. This is the actual one-time migration cost, not the local benchmark.
3. Subsequent small-table checks and the new latest query were blocked by the
   account's already-exhausted daily read quota (`7500`). This is not a successful
   production read-path acceptance test.
4. Enabled `LATEST_INDEX_ENABLED=true` after successful migration and local
   regression/independent review, to prevent the old full scan resuming after
   the quota resets. The private local `wrangler.toml` persists this flag.

The migration is additive. It does not delete retained history or create an
index covering every history row. Normal refresh frequency and retention policy
remain unchanged. The exact account-summary inspection endpoint still performs
a historical aggregate; do not poll it routinely.

## Evidence

- Six backend test groups, query-plan assertions, and a local Wrangler D1
  migration passed. Independent review also ran 600 randomized mutations against
  the original latest-query oracle.
- A local 200,000-history-row / 420-head fixture reduced latest-query SQLite
  Fullscan Steps from 399,998 to 838 (heads only), about 99.79%. These are SQLite
  diagnostics, **not** measured production D1 billing reductions.
- Identical upload retries now skip unchanged sample and device writes.
- Client `CloudSyncService` retry/fallback fixes passed 12 CloudSync tests. The
  running Mac application has not been rebuilt/replaced; other pre-existing
  user changes were deliberately left intact.

## Subsequent production verification

Using the Mac's existing HTTP proxy for the authenticated service/Cloudflare API,
the health and latest endpoints returned HTTP 200. Latest returned 24 samples;
the same latest SQL returned **176 rows read, 0 rows written, about 0.83 ms**.
Small-table validation found **26 heads, 0 invalid pointers, and all 3 triggers**.
This verifies the deployed latest path; it is not a full-day billing comparison.
The history endpoint remains blocked by the explicit existing D1 daily quota.

## Required follow-up after daily quota reset

Verify normal client refresh and the history endpoint after the existing quota
block clears. Observe a full day's actual read/write totals. Avoid re-running
the old full-history aggregate merely to measure the baseline.

If rollback is needed, redeploy **this compatible Worker** with the flag false;
do not revert to the old REPLACE writer or drop the additive tables/triggers.
See `README.md` for the phased deployment contract.
