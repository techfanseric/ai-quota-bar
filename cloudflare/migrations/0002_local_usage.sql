CREATE TABLE IF NOT EXISTS usage_members (
  team_id TEXT NOT NULL, member_id TEXT NOT NULL, member_name TEXT NOT NULL,
  PRIMARY KEY(team_id, member_id)
);
-- Separate identity and event ledger; quota snapshots remain account-level data.
CREATE TABLE IF NOT EXISTS usage_devices (
  team_id TEXT NOT NULL, device_id TEXT NOT NULL, member_id TEXT NOT NULL,
  member_name TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE,
  revoked INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL,
  PRIMARY KEY(team_id, device_id)
);
CREATE TABLE IF NOT EXISTS usage_events (
  team_id TEXT NOT NULL, event_id TEXT NOT NULL, device_id TEXT NOT NULL,
  member_id TEXT NOT NULL, occurred_at TEXT NOT NULL, model TEXT NOT NULL,
  input_tokens INTEGER NOT NULL, cached_tokens INTEGER NOT NULL,
  cache_write_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
  reasoning_tokens INTEGER NOT NULL, quality TEXT NOT NULL, parser_version INTEGER NOT NULL,
  fingerprint TEXT NOT NULL,
  PRIMARY KEY(team_id, event_id),
  FOREIGN KEY(team_id, device_id) REFERENCES usage_devices(team_id, device_id)
);
CREATE INDEX IF NOT EXISTS usage_events_team_time ON usage_events(team_id, occurred_at);
CREATE INDEX IF NOT EXISTS usage_events_member_time ON usage_events(team_id, member_id, occurred_at);
-- Retain event identities for the life of the ledger. No automatic retention deletion:
-- dropping old keys would allow offline devices to resurrect already counted events.
