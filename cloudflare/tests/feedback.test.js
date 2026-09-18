import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import worker from '../src/worker.js';

const password = 'test-only-operations-password-with-more-than-forty-chars';

function setup() {
  const db = new DatabaseSync(':memory:'); db.exec('PRAGMA foreign_keys=ON');
  // 0004 for the operator console login limiter, 0005 for the shared rate-limit
  // buckets, 0006 for the feedback table itself.
  for (const file of ['migrations/0004_operations.sql', 'migrations/0005_team_selfservice.sql', 'migrations/0006_feedback.sql']) db.exec(readFileSync(new URL('../' + file, import.meta.url), 'utf8'));
  const env = { SYNC_TOKEN: 'app-key', OPS_ADMIN_SECRET: password, DB: {
    prepare(sql) { const statement = db.prepare(sql); let args = [];
      return { bind(...values) { args = values; return this; }, async all() { return { results: statement.all(...args) }; },
        async run() { return /^\s*SELECT/i.test(sql) ? { results: statement.all(...args) } : { meta: { changes: Number(statement.run(...args).changes) } }; } }; },
    async batch(statements) { db.exec('BEGIN'); try { const values = []; for (const s of statements) values.push(await s.run()); db.exec('COMMIT'); return values; } catch (error) { db.exec('ROLLBACK'); throw error; } }
  } };
  return { db, env };
}
async function call(env, path, options = {}) {
  const headers = { 'content-type': 'application/json', ...(options.headers || {}) };
  if (options.origin !== undefined) headers.origin = options.origin;
  const response = await worker.fetch(new Request(`https://test.invalid${path}`, {
    method: options.method || (options.body !== undefined ? 'POST' : 'GET'),
    headers, body: options.body !== undefined ? JSON.stringify(options.body) : undefined }), env);
  let body = {}; try { body = await response.json(); } catch { /* static asset responses are HTML */ }
  return { status: response.status, body, response };
}
const webPost = (env, payload, headers) => call(env, '/v1/feedback', { body: payload, origin: 'https://test.invalid', headers });
const appPost = (env, payload, auth = 'app-key') => call(env, '/v1/feedback', { body: payload, headers: { authorization: `Bearer ${auth}` } });

async function loginSession(env) {
  const { response } = await call(env, '/v1/admin/login', { body: { password }, origin: 'https://test.invalid' });
  assert.equal(response.status, 200);
  return response.headers.get('set-cookie').split(';')[0];
}

test('web and app submissions share one table; contact is stored but never listed', async () => {
  const { db, env } = setup();
  const web = await webPost(env, { nickname: '小明', message: '菜单栏图标很好看！', contact: 'ming@example.com' });
  assert.equal(web.status, 200, JSON.stringify(web.body));
  assert.match(web.body.id, /^f[a-f0-9]{16}$/);
  const app = await appPost(env, { message: 'App 内直接提交', appVersion: '1.17.1', osVersion: '26.1' });
  assert.equal(app.status, 200, JSON.stringify(app.body));
  const rows = db.prepare('SELECT * FROM feedback_messages ORDER BY created_at').all();
  assert.deepEqual(rows.map(r => r.source), ['web', 'app']);
  assert.equal(rows[0].status, 'published');
  assert.equal(rows[0].contact, 'ming@example.com');
  assert.equal(rows[1].app_version, '1.17.1');
  assert.equal(rows[1].os_version, '26.1');
  const list = await call(env, '/v1/feedback');
  assert.equal(list.status, 200);
  assert.equal(list.body.total, 2);
  assert.equal(list.body.items.length, 2);
  for (const item of list.body.items) {
    assert.equal('contact' in item, false);
    assert.deepEqual(Object.keys(item).sort(), ['appVersion', 'createdAt', 'id', 'message', 'nickname', 'source'].sort());
  }
  assert.equal(list.body.items[1].nickname, '小明');
  db.close();
});

test('submission gates: cross-origin browsers and unknown clients are rejected', async () => {
  const { env } = setup();
  assert.equal((await webPost(env, { message: 'x' })).status, 200);
  assert.equal((await call(env, '/v1/feedback', { body: { message: 'x' }, origin: 'https://evil.invalid' })).status, 403);
  assert.equal((await call(env, '/v1/feedback', { body: { message: 'x' } })).status, 401);
  assert.equal((await appPost(env, { message: 'x' }, 'wrong-key')).status, 401);
  assert.equal((await call(env, '/v1/feedback', { method: 'PUT', body: { message: 'x' }, origin: 'https://test.invalid' })).status, 405);
  assert.equal((await call(env, '/v1/feedback/other', { body: { message: 'x' }, origin: 'https://test.invalid' })).status, 404);
});

test('field validation: length caps, control characters and unknown keys', async () => {
  const { db, env } = setup();
  assert.equal((await webPost(env, { message: '' })).status, 400);
  assert.equal((await webPost(env, {})).status, 400);
  assert.equal((await webPost(env, { message: 'x'.repeat(1001) })).status, 400);
  assert.equal((await webPost(env, { message: 'x'.repeat(1000) })).status, 200);
  assert.equal((await webPost(env, { message: 'bad\u0001control' })).status, 400);
  assert.equal((await webPost(env, { nickname: 'n'.repeat(31), message: 'x' })).status, 400);
  assert.equal((await webPost(env, { contact: 'c'.repeat(121), message: 'x' })).status, 400);
  assert.equal((await webPost(env, { message: '多行\n留言\t支持', appVersion: 'bad<script>' })).status, 400);
  assert.equal((await webPost(env, { message: 'x', osVersion: '26' })).status, 400);
  assert.equal((await webPost(env, { message: 'x', email: 'extra@example.com' })).status, 400);
  const multiline = await webPost(env, { message: '第一行\n第二行' });
  assert.equal(multiline.status, 200);
  assert.equal(db.prepare('SELECT message FROM feedback_messages WHERE id=?').get(multiline.body.id).message, '第一行\n第二行');
  db.close();
});

test('oversized bodies are rejected before any database write', async () => {
  const { db, env } = setup();
  assert.equal((await webPost(env, { message: 'x'.repeat(5000) })).status, 413);
  assert.equal(db.prepare('SELECT COUNT(*) n FROM feedback_messages').get().n, 0);
  db.close();
});

test('submissions are rate limited per address and hour', async () => {
  const { env } = setup();
  for (let i = 0; i < 5; i++) assert.equal((await webPost(env, { message: '第 ' + i + ' 条' })).status, 200);
  const blocked = await webPost(env, { message: '第六条' });
  assert.equal(blocked.status, 429);
  assert.equal(blocked.response.headers.get('retry-after'), '3600');
  // Invalid attempts do not consume the budget; the app path shares the same bucket by IP.
  assert.equal((await webPost(env, { message: '' })).status, 400);
  assert.equal((await appPost(env, { message: 'still blocked' })).status, 429);
});

test('public list paginates and only shows published feedback', async () => {
  const { db, env } = setup();
  for (let i = 0; i < 3; i++) db.prepare('INSERT INTO feedback_messages VALUES(?,?,?,?,?,?,?,?,?)')
    .run('f' + i.toString(16).padStart(16, '0'), '昵称' + i, '留言' + i, 'private@example.com', i === 0 ? 'app' : 'web', '1.17.1', '26.1', i === 1 ? 'hidden' : 'published', `2026-09-0${i + 1}T00:00:00.000Z`);
  const page = await call(env, '/v1/feedback?limit=1&offset=1');
  assert.equal(page.status, 200);
  assert.equal(page.body.total, 2); // hidden row is not counted
  assert.deepEqual(page.body.items.map(i => i.id), ['f' + '0'.repeat(16)]);
  assert.equal((await call(env, '/v1/feedback?limit=0')).status, 400);
  assert.equal((await call(env, '/v1/feedback?limit=51')).status, 400);
  assert.equal((await call(env, '/v1/feedback?limit=abc')).status, 400);
  assert.equal((await call(env, '/v1/feedback?offset=-1')).status, 400);
  db.close();
});

test('operator console lists everything, hides, restores and deletes feedback', async () => {
  const { db, env } = setup();
  const submitted = await webPost(env, { nickname: '小明', message: '请支持浅色菜单栏', contact: 'ming@example.com' });
  assert.equal(submitted.status, 200);
  assert.equal((await call(env, '/v1/admin/feedback')).status, 401);
  const cookie = await loginSession(env);
  const adminList = await call(env, '/v1/admin/feedback', { headers: { cookie } });
  assert.equal(adminList.status, 200, JSON.stringify(adminList.body));
  assert.equal(adminList.body.counts.published, 1);
  assert.equal(adminList.body.items[0].contact, 'ming@example.com'); // contact only appears here
  assert.equal((await call(env, '/v1/admin/feedback?limit=0', { headers: { cookie } })).status, 400);
  const hide = await call(env, '/v1/admin/feedback/status', { body: { id: submitted.body.id, status: 'hidden' }, origin: 'https://test.invalid', headers: { cookie } });
  assert.equal(hide.status, 200);
  assert.equal((await call(env, '/v1/feedback')).body.total, 0);
  assert.equal((await call(env, '/v1/admin/feedback', { headers: { cookie } })).body.counts.hidden, 1);
  assert.equal((await call(env, '/v1/admin/feedback/status', { body: { id: submitted.body.id, status: 'gone' }, origin: 'https://test.invalid', headers: { cookie } })).status, 400);
  assert.equal((await call(env, '/v1/admin/feedback/status', { body: { id: 'f' + '0'.repeat(16), status: 'hidden' }, origin: 'https://evil.invalid', headers: { cookie } })).status, 403);
  const restore = await call(env, '/v1/admin/feedback/status', { body: { id: submitted.body.id, status: 'published' }, origin: 'https://test.invalid', headers: { cookie } });
  assert.equal(restore.status, 200);
  assert.equal((await call(env, '/v1/feedback')).body.total, 1);
  const removed = await call(env, '/v1/admin/feedback?id=' + submitted.body.id, { method: 'DELETE', origin: 'https://test.invalid', headers: { cookie } });
  assert.equal(removed.status, 200);
  assert.equal(db.prepare('SELECT COUNT(*) n FROM feedback_messages').get().n, 0);
  assert.equal((await call(env, '/v1/admin/feedback?id=nope', { method: 'DELETE', origin: 'https://test.invalid', headers: { cookie } })).status, 400);
  db.close();
});

test('the /feedback page is served with API access and stays indexable', async () => {
  const { env } = setup();
  let assetPath;
  env.ASSETS = { fetch: async request => { assetPath = new URL(request.url).pathname; return new Response('<html>feedback</html>', { headers: { 'content-type': 'text/html' } }); } };
  const page = await call(env, '/feedback');
  assert.equal(page.status, 200); assert.equal(assetPath, '/feedback');
  assert.equal(page.response.headers.get('cache-control'), 'no-store');
  assert.equal(page.response.headers.get('x-robots-tag'), null); // public content, unlike /team
  assert.match(page.response.headers.get('content-security-policy'), /connect-src 'self'/);
  const trailing = await call(env, '/feedback/');
  assert.equal(trailing.status, 200); assert.equal(assetPath, '/feedback');
});
