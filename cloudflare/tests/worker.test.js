import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import worker from '../src/worker.js';

const schema = readFileSync(new URL('../schema.sql', import.meta.url), 'utf8');
const migration = readFileSync(new URL('../migrations/0001_latest_heads.sql', import.meta.url), 'utf8');
function database() {
  const db = new DatabaseSync(':memory:');
  db.exec('PRAGMA foreign_keys = ON');
  db.exec(schema);
  return db;
}
function environment(db, enabled = false) {
  const queries = [];
  return {
    queries,
    SYNC_TOKEN: 'test-only', LATEST_INDEX_ENABLED: enabled ? 'true' : undefined,
    DB: {
      prepare(sql) {
        queries.push(sql);
        const stmt = db.prepare(sql);
        let args = [];
        return {
          bind(...values) { args = values; return this; },
          async all() { return { results: stmt.all(...args) }; },
          async run() { return { meta: { changes: Number(stmt.run(...args).changes) } }; },
        };
      },
      async batch(statements) {
        db.exec('BEGIN');
        try { const result = []; for (const s of statements) result.push(await s.run()); db.exec('COMMIT'); return result; }
        catch (error) { db.exec('ROLLBACK'); throw error; }
      },
    },
  };
}
async function request(env, path, payload, method = payload ? 'POST' : 'GET') {
  const response = await worker.fetch(new Request(`https://test.invalid${path}`, {
    method, headers: { authorization: 'Bearer test-only', 'content-type': 'application/json' },
    body: payload ? JSON.stringify(payload) : undefined,
  }), env);
  const body = await response.json();
  assert.equal(response.status, 200, JSON.stringify(body));
  return body;
}
function insert(db, id, device, account, model, at, provider = 'codex') {
  db.prepare('INSERT OR IGNORE INTO devices(id) VALUES(?)').run(device);
  db.prepare(`INSERT INTO quota_samples(id,device_id,provider,account_name,model_id,model_name,
    current_interval_total,current_interval_remaining,weekly_total,weekly_remaining,sampled_at)
    VALUES(?,?,?,?,?,?,100,50,100,70,?)`).run(id, device, provider, account, model, model, at);
}
function seed(db) {
  for (let d = 0; d < 3; d++) for (let a = 0; a < 4; a++) for (let m = 0; m < 2; m++) for (let n = 0; n < 20; n++) {
    insert(db, `${d}-${a}-${m}-${n}`, `dev${d}`, [null, '', 'a', 'b'][a], `m${m}`,
      new Date(Date.UTC(2026, 8, 1, 0, n)).toISOString(), d === 2 ? 'kimi' : 'codex');
  }
}
const ids = samples => samples.map(x => x.id).sort();
async function compareLatest(db) {
  for (const suffix of ['', '&device_id=dev0', '&device_id=dev1', '&device_id=missing']) {
    const old = await request(environment(db), `/v1/quota-samples?limit=500${suffix}`);
    const next = await request(environment(db, true), `/v1/quota-samples?limit=500${suffix}`);
    assert.deepEqual(ids(next.samples), ids(old.samples));
  }
}

test('migration preserves global/device grouping, null/empty accounts and same-time ties', async () => {
  const db = database(); seed(db); db.exec(migration); await compareLatest(db);
  assert.ok(db.prepare('SELECT COUNT(*) AS n FROM quota_sample_heads').get().n < 100);
  db.exec(migration); await compareLatest(db); // additive migration is repeatable
  for (const device of [false, true]) {
    const env = environment(db, true);
    await request(env, `/v1/quota-samples?limit=500${device ? '&device_id=dev0' : ''}`);
    const plan = db.prepare(`EXPLAIN QUERY PLAN ${env.queries[0]}`).all(...(device ? ['dev0', 500] : [500]));
    const details = plan.map(x => x.detail).join('\n');
    assert.doesNotMatch(details, /SCAN quota_samples/);
    assert.match(details, /SEARCH quota_samples USING INDEX sqlite_autoindex_quota_samples_1/);
  }
  db.close();
});

test('heads stay equivalent after out-of-order insert, correction, individual deletion', async () => {
  const db = database(); seed(db); db.exec(migration);
  insert(db, 'new', 'dev0', 'a', 'm0', '2026-09-02T00:00:00.000Z');
  insert(db, 'old-arrival', 'dev0', 'a', 'm0', '2026-08-02T00:00:00.000Z');
  await compareLatest(db);
  db.prepare("UPDATE quota_samples SET account_name='moved', model_id='other' WHERE id='new'").run();
  await compareLatest(db);
  db.prepare("DELETE FROM quota_samples WHERE id='new'").run();
  db.prepare("DELETE FROM quota_samples WHERE id='0-2-0-19'").run();
  await compareLatest(db); db.close();
});

test('global history is exact bounded device merge without global sort scan', async () => {
  const db = database(); seed(db);
  const result = await request(environment(db), '/v1/quota-samples?history=1&limit=37');
  const expectedTimes = db.prepare('SELECT sampled_at FROM quota_samples ORDER BY sampled_at DESC LIMIT 37').all();
  assert.deepEqual(result.samples.map(x => x.sampled_at), expectedTimes.map(x => x.sampled_at));
  const plan = db.prepare('EXPLAIN QUERY PLAN SELECT * FROM quota_samples WHERE device_id=? ORDER BY sampled_at DESC LIMIT ?').all('dev0', 37);
  assert.match(plan.map(x => x.detail).join('\n'), /USING INDEX idx_quota_samples_device_sampled_at/);
  assert.doesNotMatch(plan.map(x => x.detail).join('\n'), /TEMP B-TREE|SCAN quota_samples/);
  db.close();
});

test('cleanup preserves cutoff/retention and prevents resurrection, both schema paths', async () => {
  for (const enabled of [false, true]) {
    const db = database(); seed(db);
    insert(db, 'expired', 'dev0', 'retired', 'm0', '2026-07-01T00:00:00.000Z');
    if (enabled) db.exec(migration);
    const env = environment(db, enabled);
    const payload = { deviceID: 'dev0', sampledAt: '2026-09-02T00:00:00.000Z', retentionDays: 30,
      models: [{ provider: 'codex', accountName: 'a', modelID: 'm0', modelName: 'model', currentIntervalTotal: 100, currentIntervalRemaining: 40 }] };
    const response = await request(env, '/v1/quota-samples', payload);
    assert.equal(response.deleted_expired_quota_samples, 1);
    assert.equal(db.prepare("SELECT COUNT(*) AS n FROM quota_samples WHERE id='expired'").get().n, 0);
    const before = db.prepare('SELECT total_changes() AS n').get().n;
    await request(env, '/v1/quota-samples', payload);
    // An identical retry rewrites neither samples nor the device heartbeat.
    assert.equal(db.prepare('SELECT total_changes() AS n').get().n - before, 0);
    if (enabled) {
      await compareLatest(db);
      await request(env, '/v1/data?provider=codex&account_name=a', null, 'DELETE');
      await compareLatest(db);
      await request(env, '/v1/data?device_id=dev1', null, 'DELETE');
      await compareLatest(db);
      assert.equal(db.prepare('PRAGMA foreign_key_check').all().length, 0);
    }
    const plan = db.prepare('EXPLAIN QUERY PLAN DELETE FROM quota_samples WHERE device_id=? AND sampled_at<?').all('dev0', '2026-08-03');
    assert.match(plan.map(x => x.detail).join('\n'), /idx_quota_samples_device_sampled_at/);
    db.close();
  }
});

test('out-of-order upload between trigger installation and backfill is pruned', async () => {
  const db = database(); seed(db);
  const split = migration.indexOf('-- Install maintenance triggers BEFORE backfill');
  db.exec(migration.slice(0, split));
  insert(db, 'concurrent-old', 'dev0', 'a', 'm0', '2026-08-01T00:00:00.000Z');
  db.exec(migration.slice(split));
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM quota_sample_heads WHERE sample_id='concurrent-old'").get().n, 0);
  await compareLatest(db);
  // A deployment that has not enabled head reads still maintains/prunes heads.
  await request(environment(db, false), '/v1/data?device_id=dev0', null, 'DELETE');
  await compareLatest(db); db.close();
});

test('deterministic mixed corrections keep exact head sets, including timestamp rollback', async () => {
  const db = database(); seed(db); db.exec(migration);
  let state = 42;
  const random = n => { state = (state * 1664525 + 1013904223) >>> 0; return state % n; };
  for (let i = 0; i < 100; i++) {
    const records = db.prepare('SELECT id FROM quota_samples ORDER BY id').all();
    const id = records[random(records.length)].id;
    if (i % 4 === 0) db.prepare('DELETE FROM quota_samples WHERE id=?').run(id);
    else db.prepare('UPDATE quota_samples SET account_name=?, model_id=?, sampled_at=? WHERE id=?')
      .run([null, '', 'a', 'b', 'moved'][random(5)], `m${random(3)}`,
        new Date(Date.UTC(2026, 8, 1, 0, random(30))).toISOString(), id);
    await compareLatest(db);
  }
  db.close();
});
