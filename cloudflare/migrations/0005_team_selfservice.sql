-- Self-service teams. A team row keeps only SHA-256 hashes of the invite code
-- and the dashboard login password; plaintext values are shown exactly once.
CREATE TABLE IF NOT EXISTS usage_teams (
  team_id TEXT PRIMARY KEY,
  team_name TEXT NOT NULL,
  invite_hash TEXT NOT NULL,
  login_hash TEXT NOT NULL,
  invite_rotated_at TEXT NOT NULL,
  created_at TEXT NOT NULL
);
-- A member passphrase guards the shared display name inside a team: a second
-- device may join an existing name only when the passphrase matches. Devices
-- authenticate with their own credential; this table is never sent to clients.
CREATE TABLE IF NOT EXISTS usage_member_secrets (
  team_id TEXT NOT NULL,
  member_id TEXT NOT NULL,
  pass_hash TEXT NOT NULL,
  PRIMARY KEY(team_id, member_id)
);
-- Fixed-window limiter shared by team creation, invite joins and team logins.
CREATE TABLE IF NOT EXISTS usage_team_limits (
  bucket TEXT PRIMARY KEY,
  attempts INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
