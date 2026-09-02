-- Additive migration. Reads existing history once; writes only current heads.
-- Deploy the UPSERT-based Worker before applying this migration, then enable
-- LATEST_INDEX_ENABLED after verification. Do not build an N-row history index.
CREATE TABLE IF NOT EXISTS quota_sample_heads (
  sample_id TEXT PRIMARY KEY REFERENCES quota_samples(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL,
  provider TEXT NOT NULL,
  account_key TEXT NOT NULL,
  model_id TEXT NOT NULL,
  sampled_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_quota_sample_heads_group
  ON quota_sample_heads(device_id, provider, account_key, model_id, sampled_at DESC);

CREATE TRIGGER IF NOT EXISTS quota_heads_insert AFTER INSERT ON quota_samples
BEGIN
  DELETE FROM quota_sample_heads
  WHERE device_id = NEW.device_id AND provider = NEW.provider
    AND account_key = COALESCE(NEW.account_name, '') AND model_id = NEW.model_id
    AND sampled_at < NEW.sampled_at;
  INSERT OR IGNORE INTO quota_sample_heads
    (sample_id, device_id, provider, account_key, model_id, sampled_at)
  SELECT NEW.id, NEW.device_id, NEW.provider, COALESCE(NEW.account_name, ''), NEW.model_id, NEW.sampled_at
  WHERE NOT EXISTS (
    SELECT 1 FROM quota_sample_heads
    WHERE device_id = NEW.device_id AND provider = NEW.provider
      AND account_key = COALESCE(NEW.account_name, '') AND model_id = NEW.model_id
      AND sampled_at > NEW.sampled_at
  );
END;

-- Bulk API deletion removes corresponding heads first, atomically, so this
-- fallback only runs for an individual head deletion outside those bulk paths.
CREATE TRIGGER IF NOT EXISTS quota_heads_delete BEFORE DELETE ON quota_samples
WHEN EXISTS (SELECT 1 FROM quota_sample_heads WHERE sample_id = OLD.id)
BEGIN
  DELETE FROM quota_sample_heads WHERE sample_id = OLD.id;
  INSERT OR IGNORE INTO quota_sample_heads
    (sample_id, device_id, provider, account_key, model_id, sampled_at)
  SELECT id, device_id, provider, COALESCE(account_name, ''), model_id, sampled_at
  FROM quota_samples
  WHERE device_id = OLD.device_id AND provider = OLD.provider
    AND COALESCE(account_name, '') = COALESCE(OLD.account_name, '')
    AND model_id = OLD.model_id AND id != OLD.id
    AND sampled_at = (
      SELECT MAX(sampled_at) FROM quota_samples
      WHERE device_id = OLD.device_id AND provider = OLD.provider
        AND COALESCE(account_name, '') = COALESCE(OLD.account_name, '')
        AND model_id = OLD.model_id AND id != OLD.id
    );
END;

-- A correction to an existing sample can move it between accounts/models or
-- change its timestamp. Reconstruct the old group and then incorporate NEW.
CREATE TRIGGER IF NOT EXISTS quota_heads_update AFTER UPDATE ON quota_samples
BEGIN
  DELETE FROM quota_sample_heads WHERE sample_id = OLD.id;
  INSERT OR IGNORE INTO quota_sample_heads
    (sample_id, device_id, provider, account_key, model_id, sampled_at)
  SELECT id, device_id, provider, COALESCE(account_name, ''), model_id, sampled_at
  FROM quota_samples
  WHERE device_id = OLD.device_id AND provider = OLD.provider
    AND COALESCE(account_name, '') = COALESCE(OLD.account_name, '')
    AND model_id = OLD.model_id
    AND sampled_at = (
      SELECT MAX(sampled_at) FROM quota_samples
      WHERE device_id = OLD.device_id AND provider = OLD.provider
        AND COALESCE(account_name, '') = COALESCE(OLD.account_name, '')
        AND model_id = OLD.model_id
    );
  DELETE FROM quota_sample_heads
  WHERE device_id = NEW.device_id AND provider = NEW.provider
    AND account_key = COALESCE(NEW.account_name, '') AND model_id = NEW.model_id
    AND sampled_at < NEW.sampled_at;
  INSERT OR IGNORE INTO quota_sample_heads
    (sample_id, device_id, provider, account_key, model_id, sampled_at)
  SELECT NEW.id, NEW.device_id, NEW.provider, COALESCE(NEW.account_name, ''), NEW.model_id, NEW.sampled_at
  WHERE NOT EXISTS (
    SELECT 1 FROM quota_sample_heads
    WHERE device_id = NEW.device_id AND provider = NEW.provider
      AND account_key = COALESCE(NEW.account_name, '') AND model_id = NEW.model_id
      AND sampled_at > NEW.sampled_at
  );
END;

-- Install maintenance triggers BEFORE backfill so concurrent uploads between
-- migration statements cannot be missed. This one SQL statement sees a coherent
-- history snapshot and only adds its actual heads; existing heads are retained.
INSERT OR IGNORE INTO quota_sample_heads
  (sample_id, device_id, provider, account_key, model_id, sampled_at)
SELECT sample.id, sample.device_id, sample.provider, COALESCE(sample.account_name, ''),
       sample.model_id, sample.sampled_at
FROM quota_samples AS sample
JOIN (
  SELECT device_id, provider, COALESCE(account_name, '') AS account_key,
         model_id, MAX(sampled_at) AS sampled_at
  FROM quota_samples
  GROUP BY device_id, provider, COALESCE(account_name, ''), model_id
) AS latest
  ON sample.device_id = latest.device_id
 AND sample.provider = latest.provider
 AND COALESCE(sample.account_name, '') = latest.account_key
 AND sample.model_id = latest.model_id
 AND sample.sampled_at = latest.sampled_at;

-- An out-of-order upload during the trigger-install/backfill window may have
-- temporarily become a head before its older group was backfilled. Prune only
-- this compact table, never re-scan the retained history.
DELETE FROM quota_sample_heads
WHERE sampled_at < (
  SELECT MAX(newer.sampled_at) FROM quota_sample_heads AS newer
  WHERE newer.device_id = quota_sample_heads.device_id
    AND newer.provider = quota_sample_heads.provider
    AND newer.account_key = quota_sample_heads.account_key
    AND newer.model_id = quota_sample_heads.model_id
);
