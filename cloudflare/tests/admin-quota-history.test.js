import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import worker from '../src/worker.js';

function setup(enabled = true) {
  const db = new DatabaseSync(':memory:'); db.exec(readFileSync(new URL('../schema.sql', import.meta.url), 'utf8')); db.exec('PRAGMA foreign_keys=ON');
  for (const file of ['0002_local_usage.sql', '0003_usage_accounts.sql', '0005_team_selfservice.sql', '0004_operations.sql', '0007_team_quota.sql', '0008_team_handoff.sql']) db.exec(readFileSync(new URL('../migrations/' + file, import.meta.url), 'utf8'));
  const env = { USAGE_ADMIN_TOKEN: 'test-administrator-token-at-least-32-characters', SYNC_TOKEN: 'legacy-token', OPS_ADMIN_SECRET: 'operator-secret-for-tests-at-least-forty-characters',
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
const model = (provider='codex', accountName='same@example.test') => ({provider,accountName,modelID:'model',modelName:'Model',currentIntervalTotal:100,currentIntervalRemaining:60,weeklyTotal:100,weeklyRemaining:80});
const auth = token => ({authorization:`Bearer ${token}`});
const upload = (env,token,models=[model()],extra={}) => post(env,'/v1/quota-samples',{deviceID:'same-device',sampledAt:new Date().toISOString(),models,...extra},auth(token));
async function createTeam(env, name = 'Fixture Team') { const r = await post(env, '/v1/team/create', { teamName: name }); assert.equal(r.status, 200, JSON.stringify(r.body)); return r.body; }
async function join(env, inviteCode, memberName, deviceID, memberPassphrase) {
  const r = await post(env, '/v1/usage/join', { inviteCode, memberName, deviceID, ...(memberPassphrase !== undefined ? { memberPassphrase } : {}) });
  assert.equal(r.status, 200, JSON.stringify(r.body)); return r.body.token;
}
async function loginSession(env, team) {
  const { response } = await post(env, '/v1/team/login', { teamID: team.teamID, password: team.loginPassword });
  assert.equal(response.status, 200);
  return response.headers.get('set-cookie').split(';')[0];
}
async function adminCookie(env) {
  const login = await post(env, '/v1/admin/login', { password: env.OPS_ADMIN_SECRET }, { origin: 'https://test.invalid' });
  assert.equal(login.status, 200);
  return login.response.headers.get('set-cookie').split(';')[0];
}
const history = (env, query, headers) => call(env, '/v1/admin/data/quota-history' + (query ? '?' + query : ''), { headers });

test('quota history is admin-only; team, device and legacy sessions never elevate',async()=>{
 const {env}=setup();const team=await createTeam(env);const token=await join(env,team.inviteCode,'A','same-device','secret-a');
 await upload(env,token,[model()],{sampledAt:new Date(Date.now()-3600000).toISOString()});
 const cookie=await loginSession(env,team);
 for(const headers of [auth(token),auth(env.SYNC_TOKEN),{cookie}])assert.equal((await history(env,'team_id='+team.teamID+'&provider=codex&account=same%40example.test',headers)).status,401);
 const headers={cookie:await adminCookie(env)};
 assert.equal((await history(env,'team_id='+team.teamID+'&provider=codex&account=same%40example.test',headers)).status,200);
});
test('history returns one team ascending samples with percent folding, scoped and never leaking',async()=>{
 const {env}=setup();const a=await createTeam(env,'A'),b=await createTeam(env,'B');
 const ta=await join(env,a.inviteCode,'Alice','same-device','secret-a'),tb=await join(env,b.inviteCode,'Bob','same-device','secret-b');
 const at=n=>new Date(Date.now()-n*3600000).toISOString();
 await upload(env,ta,[model(),{...model(),modelID:'model-pct',modelName:'Model Pct',currentIntervalRemainingPercent:42}],{sampledAt:at(3)});
 await upload(env,ta,[model()],{sampledAt:at(2)});
 await upload(env,tb,[model()],{sampledAt:at(1)});
 const headers={cookie:await adminCookie(env)};
 const query='team_id='+a.teamID+'&provider=codex&account=same%40example.test';
 const data=await history(env,query,headers);assert.equal(data.status,200);
 assert.equal(data.body.samples.length,3);
 assert.ok(data.body.samples[0].sampled_at<=data.body.samples[1].sampled_at);
 const pct=data.body.samples.find(s=>s.model_id==='model-pct');
 assert.equal(pct.current_interval_total,100);
 assert.equal(pct.current_interval_remaining,42);
 assert.equal(pct.value_suffix,'%');
 assert.equal((await history(env,'team_id='+b.teamID+'&provider=codex&account=same%40example.test',headers)).body.samples.length,1);
});
test('hours window excludes older samples; validation fails closed; unnamed account works',async()=>{
 const {env}=setup();const team=await createTeam(env);const token=await join(env,team.inviteCode,'A','same-device','secret-a');
 const headers={cookie:await adminCookie(env)};
 await upload(env,token,[model()],{sampledAt:new Date(Date.now()-30*86400000).toISOString()});
 await upload(env,token,[{...model(),accountName:''}],{sampledAt:new Date(Date.now()-3600000).toISOString()});
 const base='team_id='+team.teamID+'&provider=codex';
 assert.equal((await history(env,base+'&account=same%40example.test&hours=168',headers)).body.samples.length,0);
 assert.equal((await history(env,base+'&account=&hours=168',headers)).body.samples.length,1);
 for(const query of ['team_id=BAD ID&provider=codex','team_id='+team.teamID,'team_id='+team.teamID+'&provider='+encodeURIComponent('x'.repeat(201)),'team_id='+team.teamID+'&provider=codex&account='+encodeURIComponent('x'.repeat(201)),'team_id='+team.teamID+'&provider=codex&account=a&hours=abc','team_id='+team.teamID+'&provider=codex&account=a&hours=1000'])assert.equal((await history(env,query,headers)).status,400);
});
