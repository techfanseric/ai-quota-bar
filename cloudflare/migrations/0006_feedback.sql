-- 0006 feedback wall.
-- User-submitted feedback shown on the public /feedback page. The contact
-- column is private: it is returned only to the operator console behind
-- /v1/admin/feedback and never by the public list API.
CREATE TABLE IF NOT EXISTS feedback_messages (
  id TEXT PRIMARY KEY,
  nickname TEXT NOT NULL DEFAULT '',
  message TEXT NOT NULL,
  contact TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL CHECK(source IN ('app','web')),
  app_version TEXT NOT NULL DEFAULT '',
  os_version TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'published' CHECK(status IN ('published','hidden')),
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS feedback_by_status ON feedback_messages(status, created_at DESC);
