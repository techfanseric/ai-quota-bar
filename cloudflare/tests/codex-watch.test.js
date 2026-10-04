import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import worker from '../src/worker.js';

const SYNC = 'app-key';

function setup() {
  const db = new DatabaseSync(':memory:');
  db.exec('PRAGMA foreign_keys=ON');
  // 0005 for the shared rate-limit buckets, 0009 for the watch tables.
  for (const file of ['migrations/0005_team_selfservice.sql', 'migrations/0009_codex_watch_share.sql']) {
    db.exec(readFileSync(new URL('../' + file, import.meta.url), 'utf8'));
  }
  const env = {
    SYNC_TOKEN: SYNC,
    DB: {
      prepare(sql) {
        const statement = db.prepare(sql); let args = [];
        return {
          bind(...values) { args = values; return this; },
          async all() { return { results: statement.all(...args) }; },
          async run() {
            return /^\s*SELECT/i.test(sql)
              ? { results: statement.all(...args) }
              : { meta: { changes: Number(statement.run(...args).changes) } };
          }
        };
      },
      async batch(statements) {
        db.exec('BEGIN');
        try { const out = []; for (const s of statements) out.push(await s.run()); db.exec('COMMIT'); return out; }
        catch (error) { db.exec('ROLLBACK'); throw error; }
      }
    }
  };
  return { db, env };
}

async function call(env, path, options = {}) {
  const headers = { 'content-type': 'application/json', ...(options.headers || {}) };
  if (options.token !== null) headers.authorization = `Bearer ${options.token || SYNC}`;
  const response = await worker.fetch(new Request(`https://test.invalid${path}`, {
    method: options.method || (options.body !== undefined ? 'POST' : 'GET'),
    headers, body: options.body !== undefined ? JSON.stringify(options.body) : undefined }), env);
  let body = {}; try { body = await response.json(); } catch { /* not JSON */ }
  return { status: response.status, body };
}

const account = (name, percent = 42) => ({
  account: name,
  plan: 'Plus',
  windows: [{
    name: '5h', remainingPercent: percent,
    resetsAt: '2026-10-05T00:00:00.000Z', sampledAt: '2026-10-04T12:00:00.000Z'
  }]
});

test('every route rejects a missing or wrong app key', async () => {
  const { env } = setup();
  for (const [path, options] of [
    ['/v1/watch/publish', { method: 'POST', body: { publisher: 'p', accounts: [] } }],
    ['/v1/watch/quota?email=a@example.com', {}],
    ['/v1/watch/reads?publisher=p', {}]
  ]) {
    assert.equal((await call(env, path, { ...options, token: null })).status, 401, path);
    assert.equal((await call(env, path, { ...options, token: 'wrong' })).status, 401, path);
  }
});

test('publish then read round-trips the projection', async () => {
  const { env } = setup();
  const put = await call(env, '/v1/watch/publish', {
    body: { publisher: 'mac-a', accounts: [account('User@Example.com', 61)] }
  });
  assert.equal(put.status, 200);
  assert.equal(put.body.published, 1);

  const read = await call(env, '/v1/watch/quota?email=user%40example.com');
  assert.equal(read.status, 200);
  assert.equal(read.body.account, 'user@example.com');
  assert.equal(read.body.plan, 'Plus');
  assert.equal(read.body.windows[0].remainingPercent, 61);
  assert.ok(read.body.updated_at, 'carries the publish time');
});

test('the address is normalized before it becomes a key', async () => {
  const { env, db } = setup();
  await call(env, '/v1/watch/publish', { body: { publisher: 'mac-a', accounts: [account('  MiXeD@Case.COM ')] } });
  assert.equal((await call(env, '/v1/watch/quota?email=mixed%40case.com')).status, 200);
  // The table must not hold the plaintext address.
  const stored = db.prepare('SELECT * FROM watch_shared_quota').all();
  assert.equal(stored.length, 1);
  assert.equal(stored[0].account_key.length, 64);
  assert.ok(!JSON.stringify(stored).toLowerCase().includes('mixed@case.com'));
});

test('an unpublished address is a 404, not an error', async () => {
  const { env } = setup();
  const read = await call(env, '/v1/watch/quota?email=nobody%40example.com');
  assert.equal(read.status, 404);
  assert.equal(read.body.error, 'not_shared');
});

test('publishing replaces the whole set, so unsharing deletes', async () => {
  const { env, db } = setup();
  await call(env, '/v1/watch/publish', { body: { publisher: 'mac-a', accounts: [account('a@example.com'), account('b@example.com')] } });
  assert.equal(db.prepare('SELECT COUNT(*) n FROM watch_shared_quota').get().n, 2);

  await call(env, '/v1/watch/publish', { body: { publisher: 'mac-a', accounts: [account('a@example.com')] } });
  assert.equal(db.prepare('SELECT COUNT(*) n FROM watch_shared_quota').get().n, 1);

  // Empty set is the revoke path; it must leave nothing behind.
  const revoke = await call(env, '/v1/watch/publish', { body: { publisher: 'mac-a', accounts: [] } });
  assert.equal(revoke.body.published, 0);
  assert.equal(db.prepare('SELECT COUNT(*) n FROM watch_shared_quota').get().n, 0);
  assert.equal((await call(env, '/v1/watch/quota?email=a%40example.com')).status, 404);
});

test('one publisher cannot take over an address another publisher owns', async () => {
  const { env } = setup();
  await call(env, '/v1/watch/publish', { body: { publisher: 'mac-a', accounts: [account('a@example.com')] } });
  // Without this refusal, mac-a's later un-share would delete a row it no longer owns
  // and the account would stay published forever.
  const clash = await call(env, '/v1/watch/publish', { body: { publisher: 'mac-b', accounts: [account('a@example.com')] } });
  assert.equal(clash.status, 409);
  assert.equal(clash.body.error, 'account_published_elsewhere');
  assert.equal((await call(env, '/v1/watch/quota?email=a%40example.com')).status, 200);
});

test('re-publishing by the same owner is allowed and refreshes the row', async () => {
  const { env } = setup();
  await call(env, '/v1/watch/publish', { body: { publisher: 'mac-a', accounts: [account('a@example.com', 10)] } });
  await call(env, '/v1/watch/publish', { body: { publisher: 'mac-a', accounts: [account('a@example.com', 90)] } });
  assert.equal((await call(env, '/v1/watch/quota?email=a%40example.com')).body.windows[0].remainingPercent, 90);
});

test('a stale snapshot is 410, not a current number', async () => {
  const { env, db } = setup();
  await call(env, '/v1/watch/publish', { body: { publisher: 'mac-a', accounts: [account('a@example.com')] } });
  const longAgo = new Date(Date.now() - 5 * 3600000).toISOString();
  db.prepare('UPDATE watch_shared_quota SET updated_at=?').run(longAgo);
  const read = await call(env, '/v1/watch/quota?email=a%40example.com');
  assert.equal(read.status, 410);
  assert.equal(read.body.error, 'stale');
});

test('reads are counted and reported back to the publisher', async () => {
  const { env } = setup();
  await call(env, '/v1/watch/publish', { body: { publisher: 'mac-a', accounts: [account('a@example.com')] } });
  assert.equal((await call(env, '/v1/watch/reads?publisher=mac-a')).body.accounts[0].read_count, 0);

  await call(env, '/v1/watch/quota?email=a%40example.com');
  await call(env, '/v1/watch/quota?email=a%40example.com');

  const reads = await call(env, '/v1/watch/reads?publisher=mac-a');
  assert.equal(reads.body.accounts[0].read_count, 2);
  assert.ok(reads.body.accounts[0].last_read_at, 'records when it was read');
  assert.equal(reads.body.accounts[0].stale, false);
});

test('reads never leak the publisher of an account you do not own', async () => {
  const { env } = setup();
  await call(env, '/v1/watch/publish', { body: { publisher: 'mac-a', accounts: [account('a@example.com')] } });
  const other = await call(env, '/v1/watch/reads?publisher=mac-b');
  assert.deepEqual(other.body.accounts, []);
});

test('malformed addresses are refused instead of normalized into a key', async () => {
  const { env } = setup();
  for (const bad of ['', 'a@b', 'no-at-sign', 'a b@example.com', 'a@example..com', '@example.com', 'a@.com', 'a@example.com/x']) {
    const read = await call(env, `/v1/watch/quota?email=${encodeURIComponent(bad)}`);
    assert.equal(read.status, 400, `read should reject ${JSON.stringify(bad)}`);
    const put = await call(env, '/v1/watch/publish', { body: { publisher: 'p', accounts: [account(bad)] } });
    assert.equal(put.status, 400, `publish should reject ${JSON.stringify(bad)}`);
  }
});

test('an out-of-range percentage is refused, never clamped', async () => {
  const { env } = setup();
  for (const percent of [-1, 101, 1.5, '50', null]) {
    const entry = account('a@example.com');
    entry.windows[0].remainingPercent = percent;
    const put = await call(env, '/v1/watch/publish', { body: { publisher: 'p', accounts: [entry] } });
    assert.equal(put.status, 400, `should reject percent ${percent}`);
  }
});

test('a window must have a name and a parseable date', async () => {
  const { env } = setup();
  for (const patch of [{ name: '' }, { resetsAt: 'not-a-date' }, { sampledAt: 12345 }]) {
    const entry = account('a@example.com');
    entry.windows[0] = { ...entry.windows[0], ...patch };
    assert.equal((await call(env, '/v1/watch/publish', { body: { publisher: 'p', accounts: [entry] } })).status, 400);
  }
});

test('publish validates the publisher and the account count', async () => {
  const { env } = setup();
  assert.equal((await call(env, '/v1/watch/publish', { body: { accounts: [] } })).status, 400);
  assert.equal((await call(env, '/v1/watch/publish', { body: { publisher: 'p' } })).status, 400);
  const many = Array.from({ length: 21 }, (_, i) => account(`a${i}@example.com`));
  assert.equal((await call(env, '/v1/watch/publish', { body: { publisher: 'p', accounts: many } })).status, 400);
});

test('read rate limiting kicks in', async () => {
  const { env } = setup();
  await call(env, '/v1/watch/publish', { body: { publisher: 'mac-a', accounts: [account('a@example.com')] } });
  let limited = 0;
  for (let i = 0; i < 130; i++) {
    const read = await call(env, '/v1/watch/quota?email=a%40example.com');
    if (read.status === 429) limited++;
  }
  assert.ok(limited > 0, 'some reads are rate limited');
  // A limited read must not be counted as a real read.
  const reads = await call(env, '/v1/watch/reads?publisher=mac-a');
  assert.ok(reads.body.accounts[0].read_count <= 120);
});

test('method and path handling', async () => {
  const { env } = setup();
  assert.equal((await call(env, '/v1/watch/quota?email=a%40example.com', { method: 'POST', body: {} })).status, 405);
  assert.equal((await call(env, '/v1/watch/publish', { method: 'GET' })).status, 405);
  assert.equal((await call(env, '/v1/watch/nope')).status, 404);
});

test('the watch routes are unreachable without SYNC_TOKEN configured', async () => {
  const { env } = setup();
  delete env.SYNC_TOKEN;
  assert.equal((await call(env, '/v1/watch/quota?email=a%40example.com')).status, 401);
});
