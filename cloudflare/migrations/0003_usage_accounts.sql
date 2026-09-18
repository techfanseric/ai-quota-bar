ALTER TABLE usage_events ADD COLUMN account_id TEXT;
ALTER TABLE usage_events ADD COLUMN account_source TEXT;
CREATE INDEX IF NOT EXISTS usage_events_account_time ON usage_events(team_id,account_id,occurred_at);
