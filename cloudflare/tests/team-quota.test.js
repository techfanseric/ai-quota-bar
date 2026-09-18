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
const event = (n = 1) => ({ id: n.toString(16).padStart(64, '0'), occurredAt: '2026-09-01T12:00:00Z', model: 'fixture-model',
  tokens: { input: 1000, cached: 500, cacheWrite: 100, output: 100, reasoning: 20 }, quality: 'exact', parserVersion:1 });
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
const model = (provider='codex', accountName='same@example.test') => ({provider,accountName,modelID:'model',modelName:'Model',currentIntervalTotal:100,currentIntervalRemaining:60,weeklyTotal:100,weeklyRemaining:80});
const auth = token => ({authorization:`Bearer ${token}`});
const upload = (env,token,models=[model()],extra={}) => post(env,'/v1/quota-samples',{deviceID:'same-device',sampledAt:new Date().toISOString(),models,...extra},auth(token));
test('same device/account/model across teams never leaks through reads, writes or forged team IDs',async()=>{
 const {db,env}=setup();const a=await createTeam(env,'A'),b=await createTeam(env,'B');
 const ta=await join(env,a.inviteCode,'Alice','same-device','alice-secret'),tb=await join(env,b.inviteCode,'Bob','same-device','bob-secret');
 assert.equal((await upload(env,ta)).status,200);assert.equal((await upload(env,tb,[{...model(),currentIntervalRemaining:20}],{teamID:a.teamID})).status,200);
 for(const [token,remaining] of [[ta,60],[tb,20]]){
  for(const history of ['', '&history=1']){const r=await call(env,'/v1/quota-samples?team_id='+a.teamID+history,{headers:auth(token)});assert.equal(r.status,200);assert.equal(r.body.samples.length,1);assert.equal(r.body.samples[0].current_interval_remaining,remaining);}
  assert.equal((await call(env,'/v1/account-summaries?team_id='+b.teamID,{headers:auth(token)})).body.accounts.length,1);
 }
 assert.equal((await upload(env,ta,[model()],{deviceID:'somebody-else'})).status,400);
 assert.equal((await call(env,'/v1/data?provider=codex&account_name=same@example.test',{method:'DELETE',headers:auth(ta)})).status,403);
 assert.equal(db.prepare('SELECT COUNT(DISTINCT team_id) n FROM team_quota_samples').get().n,2);
});
test('manager deletion isolates team AND provider; forged query scope is ignored and deletion audited',async()=>{
 const {db,env}=setup();const a=await createTeam(env,'A'),b=await createTeam(env,'B');
 const ta=await join(env,a.inviteCode,'A','same-device','secret-a'),tb=await join(env,b.inviteCode,'B','same-device','secret-b');await upload(env,ta,[model(),model('kimi')]);await upload(env,tb);
 const cookie=await loginSession(env,a),path='/v1/team/accounts?'+new URLSearchParams({provider:'codex',account_name:'same@example.test',team_id:b.teamID});
 assert.equal((await call(env,path,{method:'DELETE',headers:{cookie,origin:'https://evil.test'}})).status,403);
 assert.equal((await call(env,path,{method:'DELETE',headers:{cookie}})).status,200);
 const rows=db.prepare('SELECT team_id,provider FROM team_quota_samples').all();assert.equal(rows.length,2);assert(rows.some(r=>r.team_id===b.teamID&&r.provider==='codex'));assert(rows.some(r=>r.team_id===a.teamID&&r.provider==='kimi'));
 const audit=db.prepare('SELECT * FROM team_data_audit').get();assert.equal(audit.team_id,a.teamID);assert.equal(audit.actor,'team-manager');
});
test('legacy shared data and D1 are admin-only; device/team sessions never elevate',async()=>{
 const {db,env}=setup();const team=await createTeam(env);const token=await join(env,team.inviteCode,'A','same-device','secret-a');
 db.exec("INSERT INTO devices(id) VALUES('legacy'); INSERT INTO quota_samples(id,device_id,provider,account_name,model_id,model_name,current_interval_total,current_interval_remaining,weekly_total,weekly_remaining,sampled_at) VALUES('old','legacy','codex','legacy-secret','m','M',100,10,100,50,'2026-01-01T00:00:00Z')");
 for(const path of ['/v1/quota-samples','/v1/account-summaries','/v1/devices','/v1/data?provider=codex'])assert.equal((await call(env,path,{headers:auth(env.SYNC_TOKEN),method:path.includes('/data')?'DELETE':'GET'})).status,401);
 assert.deepEqual((await call(env,'/v1/account-summaries',{headers:auth(token)})).body.accounts,[]);
 const cookie=await loginSession(env,team);
 for(const headers of [auth(token),auth(env.SYNC_TOKEN),{cookie}])for(const path of ['/v1/admin/data/teams','/v1/admin/data/legacy/accounts','/v1/admin/data/audit','/v1/admin/d1-usage'])assert.equal((await call(env,path,{headers})).status,401);
 const login=await post(env,'/v1/admin/login',{password:env.OPS_ADMIN_SECRET},{origin:'https://test.invalid'}),adminCookie=login.response.headers.get('set-cookie').split(';')[0];
 const data=await call(env,'/v1/admin/data/legacy/accounts',{headers:{cookie:adminCookie}});assert.equal(data.status,200);assert.equal(data.body.accounts[0].account_name,'legacy-secret');
 assert.equal((await call(env,'/v1/admin/data/teams',{headers:{cookie:adminCookie}})).body.teams.length,1);assert.equal(db.prepare('SELECT COUNT(*) n FROM quota_samples').get().n,1);
});
test('known device IDs cannot rotate member credentials; leaving revokes both data paths',async()=>{
 const {env}=setup();const team=await createTeam(env),token=await join(env,team.inviteCode,'Alice','same-device','alice-secret');
 assert.equal((await post(env,'/v1/usage/join',{inviteCode:team.inviteCode,memberName:'Alice',deviceID:'same-device'})).status,401);
 assert.equal((await post(env,'/v1/usage/leave',{},auth(token))).status,200);
 for(const path of ['/v1/quota-samples','/v1/usage/identity'])assert.equal((await call(env,path,{headers:auth(token)})).status,401);
 assert.equal((await upload(env,token)).status,401);
});
test('retention is server-clock based and team scoped; retries deduplicate and payload limits fail closed',async()=>{
 const {db,env}=setup();const a=await createTeam(env,'A'),b=await createTeam(env,'B'),token=await join(env,a.inviteCode,'Alice','same-device','secret-a');
 db.prepare('INSERT INTO team_quota_samples VALUES(?,?,?,?,?,?,?)').run(b.teamID,'d','codex','a','m','2020-01-01T00:00:00Z','{}');
 const sampledAt=new Date().toISOString();await upload(env,token,[model()],{sampledAt});await upload(env,token,[model()],{sampledAt});
 assert.equal(db.prepare('SELECT COUNT(*) n FROM team_quota_samples WHERE team_id=?').get(a.teamID).n,1);assert.equal(db.prepare('SELECT COUNT(*) n FROM team_quota_samples WHERE team_id=?').get(b.teamID).n,1);
 assert.equal((await upload(env,token,[model()],{sampledAt:'2999-01-01T00:00:00Z'})).status,400);assert.equal((await upload(env,token,Array(101).fill(model()))).status,400);assert.equal((await upload(env,token,[model()],{padding:'x'.repeat(270000)})).status,413);
});

test('native handoffs are one-use and members can inspect only their team, never manage it',async()=>{
 const {db,env}=setup(),a=await createTeam(env,'A'),b=await createTeam(env,'B');
 const ta=await join(env,a.inviteCode,'Alice','same-device','secret-a'),tb=await join(env,b.inviteCode,'Bob','same-device','secret-b');
 await upload(env,ta);await upload(env,tb);
 const start=await post(env,'/v1/team/handoff',{},auth(ta));assert.equal(start.status,200);assert.equal(start.body.role,'member');
 assert(!JSON.stringify(db.prepare('SELECT * FROM team_browser_handoffs').all()).includes(start.body.ticket));
 const redeem=await post(env,'/v1/team/redeem',{ticket:start.body.ticket},{origin:'https://test.invalid'});assert.equal(redeem.status,200);
 assert.equal((await post(env,'/v1/team/redeem',{ticket:start.body.ticket},{origin:'https://test.invalid'})).status,401);
 const headers={cookie:redeem.response.headers.get('set-cookie').split(';')[0]};
 const overview=await call(env,'/v1/team/overview?team_id='+b.teamID,{headers});assert.equal(overview.status,200);assert.equal(overview.body.team.teamID,a.teamID);assert.equal(overview.body.access.canManage,false);
 assert.equal((await call(env,'/v1/team/accounts',{headers})).body.accounts.length,1);
 for(const path of ['/v1/team/invite/rotate','/v1/team/devices/revoke','/v1/team/members/revoke'])assert.equal((await post(env,path,{},headers)).status,403);
 assert.equal((await call(env,'/v1/team/accounts?provider=codex&account_name=same@example.test',{method:'DELETE',headers})).status,403);
 db.prepare('UPDATE usage_devices SET revoked=1 WHERE team_id=?').run(a.teamID);
 assert.equal((await call(env,'/v1/team/overview',{headers})).status,401);
});
test('manager handoff verifies current team password and ticket lifetime, origin and revocation',async()=>{
 const {db,env}=setup(),a=await createTeam(env,'A'),b=await createTeam(env,'B');const ta=await join(env,a.inviteCode,'Alice','same-device','secret-a');
 assert.equal((await post(env,'/v1/team/handoff',{managementPassword:b.loginPassword},auth(ta))).status,401);
 const make=async()=>{const r=await post(env,'/v1/team/handoff',{managementPassword:a.loginPassword},auth(ta));assert.equal(r.status,200);return r.body.ticket;};
 let ticket=await make();assert.equal((await post(env,'/v1/team/redeem',{ticket},{origin:'https://evil.test'})).status,403);
 const r=await post(env,'/v1/team/redeem',{ticket},{origin:'https://test.invalid'});assert.equal(r.status,200);
 const cookie=r.response.headers.get('set-cookie').split(';')[0];assert.equal((await call(env,'/v1/team/overview',{headers:{cookie}})).body.access.canManage,true);
 assert.equal((await post(env,'/v1/team/invite/rotate',{}, {cookie})).status,200);
 ticket=await make();db.prepare('UPDATE team_browser_handoffs SET expires_at=0').run();assert.equal((await post(env,'/v1/team/redeem',{ticket},{origin:'https://test.invalid'})).status,401);
 ticket=await make();db.prepare('UPDATE usage_devices SET revoked=1 WHERE team_id=?').run(a.teamID);assert.equal((await post(env,'/v1/team/redeem',{ticket},{origin:'https://test.invalid'})).status,401);
});

test('browser session changes across tabs cannot target another team and forged member cookies fail',async()=>{
 const {db,env}=setup(),a=await createTeam(env,'A'),b=await createTeam(env,'B');
 const ta=await join(env,a.inviteCode,'Alice','same-device','secret-a');
 const bCookie=await loginSession(env,b);
 const before=db.prepare('SELECT invite_hash FROM usage_teams WHERE team_id=?').get(b.teamID).invite_hash;
 assert.equal((await post(env,'/v1/team/invite/rotate',{}, {cookie:bCookie,'x-aqb-team':a.teamID})).status,409);
 assert.equal(db.prepare('SELECT invite_hash FROM usage_teams WHERE team_id=?').get(b.teamID).invite_hash,before);
 const handoff=await post(env,'/v1/team/handoff',{},auth(ta));
 const redeem=await post(env,'/v1/team/redeem',{ticket:handoff.body.ticket},{origin:'https://test.invalid'});
 const cookie=redeem.response.headers.get('set-cookie').split(';')[0],parts=cookie.split('.');
 const payload=JSON.parse(Buffer.from(parts[1],'base64url'));payload.teamID=b.teamID;
 parts[1]=Buffer.from(JSON.stringify(payload)).toString('base64url');
 assert.equal((await call(env,'/v1/team/overview',{headers:{cookie:parts.join('.')}})).status,401);
 assert.equal((await call(env,'/v1/admin/data/teams',{headers:{cookie}})).status,401);
 db.prepare('UPDATE usage_devices SET token_hash=? WHERE team_id=?').run('rotated',a.teamID);
 assert.equal((await call(env,'/v1/team/overview',{headers:{cookie}})).status,401);
});
