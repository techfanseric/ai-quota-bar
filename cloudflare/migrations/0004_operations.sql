-- Product analytics are separate from account quotas and team usage.
CREATE TABLE IF NOT EXISTS telemetry_installs (
  id TEXT PRIMARY KEY,
  first_seen_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  app_version TEXT NOT NULL,
  app_build TEXT NOT NULL,
  os_version TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS telemetry_installs_last_seen ON telemetry_installs(last_seen_at);
CREATE TABLE IF NOT EXISTS telemetry_days (
  day TEXT NOT NULL,
  install_id TEXT NOT NULL,
  active INTEGER NOT NULL DEFAULT 0 CHECK(active IN (0,1)),
  PRIMARY KEY(day, install_id),
  FOREIGN KEY(install_id) REFERENCES telemetry_installs(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS telemetry_days_install ON telemetry_days(install_id,day);
CREATE TABLE IF NOT EXISTS ops_login_limits (
  bucket TEXT PRIMARY KEY,
  attempts INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);

-- Only a revocation hash remains, to reject in-flight retries after erasure.
CREATE TABLE IF NOT EXISTS telemetry_revocations (id TEXT PRIMARY KEY);
