-- Legacy tables remain quarantined; no account-name based automatic adoption.
CREATE TABLE IF NOT EXISTS team_quota_samples (
 team_id TEXT NOT NULL, device_id TEXT NOT NULL, provider TEXT NOT NULL,
 account_key TEXT NOT NULL, model_id TEXT NOT NULL, sampled_at TEXT NOT NULL,
 payload TEXT NOT NULL,
 PRIMARY KEY(team_id,device_id,provider,account_key,model_id,sampled_at)
);
CREATE INDEX IF NOT EXISTS team_quota_time ON team_quota_samples(team_id,sampled_at DESC);
CREATE INDEX IF NOT EXISTS team_quota_device_time ON team_quota_samples(team_id,device_id,sampled_at DESC);
CREATE TABLE IF NOT EXISTS team_quota_heads (
 team_id TEXT NOT NULL, device_id TEXT NOT NULL, provider TEXT NOT NULL,
 account_key TEXT NOT NULL, model_id TEXT NOT NULL, sampled_at TEXT NOT NULL,
 payload TEXT NOT NULL,
 PRIMARY KEY(team_id,device_id,provider,account_key,model_id)
);
CREATE TABLE IF NOT EXISTS team_data_audit (
 id TEXT PRIMARY KEY, team_id TEXT NOT NULL, actor TEXT NOT NULL,
 action TEXT NOT NULL, target TEXT NOT NULL, created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS team_audit_time ON team_data_audit(team_id,created_at DESC);
