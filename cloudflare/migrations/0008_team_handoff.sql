-- One-time native-app to browser handoffs. Only hashes are stored; tickets expire in two minutes.
CREATE TABLE IF NOT EXISTS team_browser_handoffs (
 token_hash TEXT PRIMARY KEY,
 team_id TEXT NOT NULL,
 role TEXT NOT NULL CHECK(role IN ('manager','member')),
 device_id TEXT NOT NULL,
 device_token_hash TEXT NOT NULL,
 login_hash TEXT NOT NULL,
 expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS team_browser_handoffs_expiry ON team_browser_handoffs(expires_at);
