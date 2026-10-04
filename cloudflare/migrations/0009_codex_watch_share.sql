-- Cross-device Codex watch: an owner publishes the quota of the accounts it has
-- explicitly ticked, and any install that knows an address can read that address's
-- snapshot. No team, no per-device credential, no shared secret to type.
--
-- The account key is a SHA-256 of the normalized address, so the table never holds a
-- plaintext email. That is hygiene, not secrecy: the read endpoint looks up by
-- address, so anyone who knows the address can compute the same key.
CREATE TABLE IF NOT EXISTS watch_shared_quota (
  account_key TEXT PRIMARY KEY,
  publisher_id TEXT NOT NULL,
  payload TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
-- Lets a publisher replace its whole set in one statement and lets the read-count
-- query find the accounts a given publisher owns.
CREATE INDEX IF NOT EXISTS watch_shared_quota_publisher ON watch_shared_quota(publisher_id);

-- Who is actually reading a published account. Count and time only, no viewer
-- identity: the read path is deliberately open, and the owner's leverage is
-- "uncheck to revoke", not "blocklist individual readers".
CREATE TABLE IF NOT EXISTS watch_reads (
  account_key TEXT PRIMARY KEY,
  read_count INTEGER NOT NULL DEFAULT 0,
  last_read_at TEXT NOT NULL
);
