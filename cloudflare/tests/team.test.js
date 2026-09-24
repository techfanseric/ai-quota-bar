import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import worker from '../src/worker.js';

function setup(enabled = true) {
  const db = new DatabaseSync(':memory:'); db.exec('PRAGMA foreign_keys=ON');
  for (const file of ['0002_local_usage.sql', '0003_usage_accounts.sql', '0004_operations.sql', '0005_team_selfservice.sql']) db.exec(readFileSync(new URL('../migrations/' + file, import.meta.url), 'utf8'));
  const env = { USAGE_ADMIN_TOKEN: 'test-administrator-token-at-least-32-characters', SYNC_TOKEN: 'legacy-token',
    ...(enabled ? { USAGE_TEAMS_ENABLED: 'true' } : {}), DB: {
      prepare(sql) { const statement = db.prepare(sql); let args = [];
        return { bind(...values) { args = values; return this; }, async all() { return { results: statement.all(...args) }; },
          async run() { return /^\s*SELECT/i.test(sql) ? { results: statement.all(...args) } : { meta: { changes: Number(statement.run(...args).changes) } }; } }; },
      async batch(statements) { db.exec('BEGIN'); try { const values = []; for (const s of statements) values.push(await s.run()); db.exec('COMMIT'); return values; } catch (error) { db.exec('ROLLBACK'); throw error; } }
    } };
  return { db, env };
}
async function call(env, path, options = {}) {
  const response = await worker.fetch(new Request(`https://test.invalid${path}`, { ...options, headers: { 'content-type': 'application/json', ...(options.headers || {}) } }), env);
  let body = {}; try { body = await response.json(); } catch { /* static asset responses are HTML */ }
  return { status: response.status, body, response };
}
const post = (env, path, payload, headers) => call(env, path, { method: 'POST', body: payload === undefined ? undefined : JSON.stringify(payload), headers });
const event = (n = 1) => ({ id: n.toString(16).padStart(64, '0'), occurredAt: '2026-09-01T12:00:00Z', model: 'fixture-model',
  tokens: { input: 1000, cached: 500, cacheWrite: 100, output: 100, reasoning: 20 }, quality: 'exact', parserVersion:1 });
async function createTeam(env, name = 'Fixture Team') { const r = await post(env, '/v1/team/create', { teamName: name }); assert.equal(r.status, 200, JSON.stringify(r.body)); return r.body; }
async function join(env, inviteCode, memberName, deviceID, memberPassphrase) {
  const r = await post(env, '/v1/usage/join', { inviteCode, memberName, deviceID, ...(memberPassphrase !== undefined ? { memberPassphrase } : {}) });
  assert.equal(r.status, 200, JSON.stringify(r.body)); return r.body.token;
}

test('team creation stores only hashes and hands credentials out exactly once', async () => {
  const { db, env } = setup();
  const team = await createTeam(env);
  assert.match(team.teamID, /^t[a-f0-9]{16}$/); assert.match(team.inviteCode, /^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$/); assert.ok(team.loginPassword.length >= 10);
  const row = db.prepare('SELECT * FROM usage_teams').get();
  assert.equal(row.team_name, 'Fixture Team');
  assert(![team.inviteCode, team.loginPassword].some(secret => JSON.stringify(row).includes(secret)));
  await post(env, '/v1/team/create', { teamName: '' }, 0 && {}); // invalid name still counts toward the limit below
  for (let i = 0; i < 2; i++) await post(env, '/v1/team/create', { teamName: 'Extra ' + i });
  assert.equal((await post(env, '/v1/team/create', { teamName: 'Fourth' })).status, 429);
  await post(env, '/v1/team/create', { teamName: 'x'.repeat(61) }, undefined);
  db.close();
});

test('members join with an invite code and a name; usage aggregates by member and account', async () => {
  const { db, env } = setup();
  const team = await createTeam(env);
  const alice = await join(env, team.inviteCode.toLowerCase().replace(/-/g, ' '), 'Alice', 'mac-alice');
  const bob = await join(env, team.inviteCode, 'Bob', 'mac-bob', 'hunter2');
  for (const [token, e] of [[alice, event(1)], [bob, event(2)]]) {
    const r = await post(env, '/v1/usage/events/batch', { events: [e] }, { authorization: `Bearer ${token}` });
    assert.equal(r.status, 200, JSON.stringify(r.body));
  }
  const summary = await call(env, '/v1/usage/summary?from=2026-08-01T00:00:00Z&to=2026-10-01T00:00:00Z', { headers: { authorization: `Bearer ${alice}` } });
  assert.equal(summary.status, 200);
  assert.deepEqual(summary.body.groups.map(g => g.name).sort(), ['Alice', 'Bob']);
  const secondMac = await join(env, team.inviteCode, 'Bob', 'mac-bob-2', 'hunter2');
  assert.notEqual(secondMac, bob);
  db.close();
});

test('a shared name cannot be claimed without the member passphrase', async () => {
  const { env } = setup();
  const team = await createTeam(env);
  const first = await join(env, team.inviteCode, 'Alice', 'mac-alice'); // no passphrase stored yet
  assert.equal((await post(env, '/v1/usage/join', { inviteCode: team.inviteCode, memberName: 'Alice', deviceID: 'mac-evil' })).status, 409);
  const set = await post(env, '/v1/usage/member/passphrase', { passphrase: 'correct horse' }, { authorization: `Bearer ${first}` });
  assert.equal(set.status, 200);
  const wrong = await post(env, '/v1/usage/join', { inviteCode: team.inviteCode, memberName: 'Alice', deviceID: 'mac-evil', memberPassphrase: 'nope' });
  assert.equal(wrong.status, 401);
  const right = await post(env, '/v1/usage/join', { inviteCode: team.inviteCode, memberName: 'Alice', deviceID: 'mac-2', memberPassphrase: 'correct horse' });
  assert.equal(right.status, 200);
});

test('a bound device only switches member when that member proves consent', async () => {
  const { env } = setup();
  const team = await createTeam(env);
  await join(env, team.inviteCode, 'Alice', 'shared-mac');
  await join(env, team.inviteCode, 'Bob', 'mac-bob', 'bob-secret');
  // The shared Mac is bound to Alice; claiming Bob's (existing) name needs Bob's passphrase.
  assert.equal((await post(env, '/v1/usage/join', { inviteCode: team.inviteCode, memberName: 'Bob', deviceID: 'shared-mac', memberPassphrase: 'wrong' })).status, 401);
  assert.equal((await post(env, '/v1/usage/join', { inviteCode: team.inviteCode, memberName: 'Bob', deviceID: 'shared-mac' })).status, 401);
  // A brand-new name on a bound device is never allowed.
  assert.equal((await post(env, '/v1/usage/join', { inviteCode: team.inviteCode, memberName: 'Carol', deviceID: 'shared-mac' })).status, 409);
  // With Bob's passphrase the shared Mac moves to Bob (the admin --reassign flow).
  const moved = await post(env, '/v1/usage/join', { inviteCode: team.inviteCode, memberName: 'Bob', deviceID: 'shared-mac', memberPassphrase: 'bob-secret' });
  assert.equal(moved.status, 200);
});

test('team membership is capped and invite rotation invalidates old codes', async () => {
  const { env } = setup();
  const team = await createTeam(env);
  await join(env, team.inviteCode, 'Bob', 'mac-bob', 'hunter2'); // cap is 20 including this member
  for (let i = 0; i < 19; i++) await join(env, team.inviteCode, 'Member ' + i, 'mac-' + i);
  const full = await post(env, '/v1/usage/join', { inviteCode: team.inviteCode, memberName: 'Overflow', deviceID: 'mac-x' });
  assert.equal(full.status, 403);
  const session = await loginSession(env, team);
  const rotated = await post(env, '/v1/team/invite/rotate', {}, { cookie: session });
  assert.equal(rotated.status, 200); assert.ok(rotated.body.inviteCode);
  assert.equal((await post(env, '/v1/usage/join', { inviteCode: team.inviteCode, memberName: 'Bob', deviceID: 'mac-late', memberPassphrase: 'hunter2' })).status, 401);
  const fresh = await post(env, '/v1/usage/join', { inviteCode: rotated.body.inviteCode, memberName: 'Bob', deviceID: 'mac-late', memberPassphrase: 'hunter2' });
  assert.equal(fresh.status, 200);
});

test('dashboard session: login, overview, revoke; wrong passwords and tampering rejected', async () => {
  const { db, env } = setup();
  const team = await createTeam(env);
  const token = await join(env, team.inviteCode, 'Alice', 'mac-alice');
  await post(env, '/v1/usage/events/batch', { events: [{ ...event(1), accountID: 'a'.repeat(64), accountSource: 'log' }] }, { authorization: `Bearer ${token}` });
  assert.equal((await post(env, '/v1/team/login', { teamID: team.teamID, password: 'wrong' })).status, 401);
  assert.equal((await post(env, '/v1/team/login', { teamID: team.teamID, password: team.loginPassword }, { origin: 'https://evil.example' })).status, 403);
  const { response } = await post(env, '/v1/team/login', { teamID: team.teamID, password: team.loginPassword });
  const cookie = response.headers.get('set-cookie').split(';')[0];
  assert.equal((await call(env, '/v1/team/overview?days=30')).status, 401);
  const tampered = await call(env, '/v1/team/overview?days=30', { headers: { cookie: cookie.slice(0, -4) + 'beef' } });
  assert.equal(tampered.status, 401);
  const overview = await call(env, '/v1/team/overview?days=30', { headers: { cookie } });
  assert.equal(overview.status, 200, JSON.stringify(overview.body));
  assert.equal(overview.body.team.teamName, 'Fixture Team');
  assert.equal(overview.body.members.length, 1);
  assert.equal(overview.body.members[0].memberName, 'Alice');
  assert.equal(overview.body.members[0].devices[0].deviceID, 'mac-alice');
  assert.equal(overview.body.usage.member[0].input + overview.body.usage.member[0].output, 1100);
  assert.equal(overview.body.usage.account[0].id, 'a'.repeat(64));
  assert.equal((await call(env, '/v1/team/overview?days=31', { headers: { cookie } })).status, 400);
  const revoked = await post(env, '/v1/team/devices/revoke', { deviceID: 'mac-alice' }, { cookie });
  assert.equal(revoked.status, 200);
  assert.equal((await call(env, '/v1/usage/identity', { headers: { authorization: `Bearer ${token}` } })).status, 401);
  assert.equal((await post(env, '/v1/team/logout', {}, { cookie })).status, 200);
  db.close();
});

test('login attempts are rate limited per team and address', async () => {
  const { env } = setup();
  const team = await createTeam(env);
  for (let i = 0; i < 10; i++) await post(env, '/v1/team/login', { teamID: team.teamID, password: 'wrong' });
  const blocked = await post(env, '/v1/team/login', { teamID: team.teamID, password: team.loginPassword });
  assert.equal(blocked.status, 429);
});

test('self-service endpoints stay closed until the deployment opts in', async () => {
  const { env } = setup(false);
  assert.equal((await post(env, '/v1/team/create', { teamName: 'Nope' })).status, 503);
  assert.equal((await post(env, '/v1/team/login', { teamID: 't' + '0'.repeat(16), password: 'x' })).status, 503);
  assert.equal((await post(env, '/v1/usage/join', { inviteCode: 'ABCD2345EFGH', memberName: 'A', deviceID: 'd' })).status, 503);
});

test('the /team console shell is served uncacheable and unindexed', async () => {
  const { env } = setup();
  let assetPath;
  env.ASSETS = { fetch: async request => { assetPath = new URL(request.url).pathname; return new Response('<html>team</html>', { headers: { 'content-type': 'text/html' } }); } };
  const page = await call(env, '/team');
  assert.equal(page.status, 200); assert.equal(assetPath, '/team');
  assert.equal(page.response.headers.get('cache-control'), 'no-store');
  assert.equal(page.response.headers.get('x-robots-tag'), 'noindex, nofollow');
  assert.match(page.response.headers.get('content-security-policy'), /connect-src 'self'/);
});

async function loginSession(env, team) {
  const { response } = await post(env, '/v1/team/login', { teamID: team.teamID, password: team.loginPassword });
  assert.equal(response.status, 200);
  return response.headers.get('set-cookie').split(';')[0];
}

test('platform admin opens any team dashboard without its password, including device-only teams', async () => {
  const { db, env } = setup();
  env.OPS_ADMIN_SECRET = 'test-ops-secret-with-more-than-forty-characters!!';
  const origin = { origin: 'https://test.invalid' };
  const team = await createTeam(env, 'Managed Team');
  await join(env, team.inviteCode, 'Alice', 'mac-alice');
  const adminCookie = (await post(env, '/v1/admin/login', { password: env.OPS_ADMIN_SECRET }, origin)).response.headers.get('set-cookie').split(';')[0];
  assert.equal((await post(env, '/v1/admin/team-session', { teamID: team.teamID }, origin)).status, 401);
  assert.equal((await post(env, '/v1/admin/team-session', { teamID: team.teamID }, { cookie: adminCookie, origin: 'https://evil.example' })).status, 403);
  assert.equal((await post(env, '/v1/admin/team-session', { teamID: 'no-such-team' }, { cookie: adminCookie, ...origin })).status, 404);
  const minted = await post(env, '/v1/admin/team-session', { teamID: team.teamID }, { cookie: adminCookie, ...origin });
  assert.equal(minted.status, 200, JSON.stringify(minted.body));
  const teamCookie = minted.response.headers.get('set-cookie').split(';')[0];
  assert.match(teamCookie, /^__Host-aqb_team=admin\./);
  const overview = await call(env, '/v1/team/overview?days=30', { headers: { cookie: teamCookie } });
  assert.equal(overview.status, 200, JSON.stringify(overview.body));
  assert.equal(overview.body.access.role, 'manager');
  assert.equal(overview.body.team.teamName, 'Managed Team');
  assert.equal((await call(env, '/v1/team/overview?days=30', { headers: { cookie: teamCookie.slice(0, -4) + 'beef' } })).status, 401);
  db.prepare('DELETE FROM usage_teams WHERE team_id=?').run(team.teamID);
  const legacy = await post(env, '/v1/admin/team-session', { teamID: team.teamID }, { cookie: adminCookie, ...origin });
  assert.equal(legacy.status, 200);
  const legacyOverview = await call(env, '/v1/team/overview?days=30', { headers: { cookie: legacy.response.headers.get('set-cookie').split(';')[0] } });
  assert.equal(legacyOverview.status, 200, JSON.stringify(legacyOverview.body));
  assert.equal(legacyOverview.body.team.teamName, team.teamID);
  assert.equal(legacyOverview.body.members[0].memberName, 'Alice');
  assert.equal((await post(env, '/v1/team/invite/rotate', {}, { cookie: legacy.response.headers.get('set-cookie').split(';')[0] })).status, 404);
  db.close();
});
