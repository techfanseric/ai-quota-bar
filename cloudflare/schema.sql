CREATE TABLE IF NOT EXISTS devices (
  id TEXT PRIMARY KEY,
  name TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  last_seen_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE IF NOT EXISTS quota_samples (
  id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL,
  provider TEXT NOT NULL,
  account_name TEXT,
  model_id TEXT NOT NULL,
  model_name TEXT NOT NULL,
  current_interval_total INTEGER NOT NULL,
  current_interval_remaining INTEGER NOT NULL,
  weekly_total INTEGER NOT NULL,
  weekly_remaining INTEGER NOT NULL,
  reset_start_time TEXT,
  reset_end_time TEXT,
  weekly_start_time TEXT,
  weekly_end_time TEXT,
  value_suffix TEXT,
  detail_text TEXT,
  sampled_at TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  FOREIGN KEY (device_id) REFERENCES devices(id)
);

CREATE INDEX IF NOT EXISTS idx_quota_samples_device_sampled_at
  ON quota_samples(device_id, sampled_at DESC);

CREATE INDEX IF NOT EXISTS idx_quota_samples_model_sampled_at
  ON quota_samples(device_id, provider, model_id, sampled_at DESC);

CREATE TABLE IF NOT EXISTS settings (
  device_id TEXT NOT NULL,
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  PRIMARY KEY (device_id, key),
  FOREIGN KEY (device_id) REFERENCES devices(id)
);
