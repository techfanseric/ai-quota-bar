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
 for(const query of ['team_id=BAD ID&provider=codex','team_id='+team.teamID,'team_id='+team.teamID+'&provider='+encodeURIComponent('x'.repeat(201)),'team_id='+team.teamID+'&provider=codex&account='+encodeURIComponent('x'.repeat(201)),'team_id='+team.teamID+'&provider=codex&account=a&hours=abc','team_id='+team.teamID+'&provider=codex&account=a&hours=2161','team_id='+team.teamID+'&provider=codex&account=a&hours=0'])assert.equal((await history(env,query,headers)).status,400);
 // 90 天上限对齐服务端保留期：30 天前的样本在 7 天窗口外，但必须在 90 天窗口内可见。
 const wide=(await history(env,base+'&account=same%40example.test&hours=2160',headers)).body;
 assert.equal(wide.hours,2160);
 assert.equal(wide.samples.length,1);
 assert.equal(wide.truncated,false);
});
test('history rejects unknown filters instead of silently answering with the default window',async()=>{
 const {env}=setup();const team=await createTeam(env);
 const headers={cookie:await adminCookie(env)};
 const base='team_id='+team.teamID+'&provider=codex&account=a';
 // from/to 曾经被静默忽略并返回 200 + 默认 7 天，看起来像个能用的日期区间。
 for(const query of [base+'&from=2026-01-01&to=2026-02-01',base+'&date=2026-09-01',base+'&window=90d']){
  const result=await history(env,query,headers);
  assert.equal(result.status,400,query);
  assert.equal(result.body.error,'invalid_parameter',query);
 }
 // 已知参数全部放行。
 assert.equal((await history(env,base+'&hours=24&model=gpt-5',headers)).status,200);
});
test('history keeps the newest rows when a window overflows the row budget, and says so',async()=>{
 const {db,env}=setup();const team=await createTeam(env);
 const at=ms=>new Date(ms).toISOString();
 // 直接铺 6000 行（两个模型各 3000），越过 5000 的预算，避免真的发 6000 次上传。
 const now=Date.now();
 db.exec('BEGIN');
 for(let i=0;i<3000;i++){
  const at=now-(3000-i)*1000,iso=new Date(at).toISOString();
  // 写入方把 sampled_at 存进 payload（team-quota.js 的 upload 路径），这里保持一致。
  for(const model of ['m','n'])
   db.prepare('INSERT OR IGNORE INTO team_quota_samples VALUES(?,?,?,?,?,?,?)')
    .run(team.teamID,'dev','codex','a@example.test',model,iso,
     JSON.stringify({model_id:model,current_interval_total:100,current_interval_remaining:i,value_suffix:'%',sampled_at:iso}));
 }
 db.exec('COMMIT');
 const headers={cookie:await adminCookie(env)};
 const body=(await history(env,'team_id='+team.teamID+'&provider=codex&account=a%40example.test&hours=168',headers)).body;
 assert.equal(body.samples.length,5000);
 assert.equal(body.truncated,true);
 assert.equal(body.row_budget,5000);
 // 保留的必须是最新的 5000 条：升序，且收尾是窗口内最后一行的那个值。
 assert.ok(body.samples[0].sampled_at<body.samples.at(-1).sampled_at);
 assert.equal(body.samples.at(-1).current_interval_remaining,2999);
 // 按 model 过滤后行数减半，不再超预算，截断标记随之消失。
 const one=(await history(env,'team_id='+team.teamID+'&provider=codex&account=a%40example.test&hours=168&model=m',headers)).body;
 assert.equal(one.truncated,false);
 assert.equal(one.model,'m');
 assert.equal(one.samples.length,3000);
 assert.ok(one.samples.every(sample=>sample.model_id==='m'));
});
test('history model filter returns only that model and stays scoped to the team',async()=>{
 const {db,env}=setup();const a=await createTeam(env,'A'),b=await createTeam(env,'B');
 const at=ms=>new Date(ms).toISOString();
 const put=(team,device,model,minutes,payload)=>db.prepare('INSERT OR IGNORE INTO team_quota_samples VALUES(?,?,?,?,?,?,?)')
  .run(team,device,'codex','a@example.test',model,at(Date.now()-minutes*60000),JSON.stringify(payload));
 for(const team of [a.teamID,b.teamID]){
  for(const minutes of [3,2,1]){
   put(team,'dev','gpt-5',minutes,{model_id:'gpt-5',current_interval_total:100,current_interval_remaining:minutes*10,value_suffix:'%'});
   put(team,'dev','gpt-4',minutes,{model_id:'gpt-4',current_interval_total:100,current_interval_remaining:minutes*20,value_suffix:'%'});
  }
 }
 const headers={cookie:await adminCookie(env)};
 const base='provider=codex&account=a%40example.test&hours=168';
 const all=(await history(env,base+'&team_id='+a.teamID,headers)).body;
 assert.equal(all.samples.length,6);
 const only=(await history(env,base+'&team_id='+a.teamID+'&model=gpt-5',headers)).body;
 assert.equal(only.samples.length,3);
 assert.ok(only.samples.every(sample=>sample.model_id==='gpt-5'));
 // 过滤不能跨团队：另一个团队的数据不会因为同账号名而混进来。
 assert.equal((await history(env,base+'&team_id='+b.teamID,headers)).body.samples.length,6);
 assert.equal((await history(env,base+'&team_id='+a.teamID+'&model=nope',headers)).body.samples.length,0);
});

test('the account roster keeps the newest snapshots and flags that it was capped',async()=>{
 const {db,env}=setup();const team=await createTeam(env);
 const now=Date.now();
 // 2100 个不同模型，跨过 2000 的名册上限。
 db.exec('BEGIN');
 for(let i=0;i<2100;i++)
  db.prepare('INSERT OR IGNORE INTO team_quota_heads VALUES(?,?,?,?,?,?,?)')
   .run(team.teamID,'dev','codex','a@example.test','m'+i,new Date(now-(2100-i)*1000).toISOString(),
    JSON.stringify({model_id:'m'+i,current_interval_total:100,current_interval_remaining:i,value_suffix:'%'}));
 db.exec('COMMIT');
 const headers={cookie:await adminCookie(env)};
 const body=(await call(env,'/v1/admin/data/quota',{headers})).body;
 assert.equal(body.items.length,2000);
 assert.equal(body.truncated,true);
 assert.equal(body.row_budget,2000);
 // 留下的是最新上报的那批，最老的不在里面。
 const kept=new Set(body.items.map(item=>item.model_id));
 assert.ok(kept.has('m2099'));
 assert.ok(!kept.has('m0'));
 // 团队内收窄时也照常工作。
 const scoped=(await call(env,'/v1/admin/data/quota?team_id='+team.teamID,{headers})).body;
 assert.equal(scoped.truncated,true);
 assert.equal(scoped.items.length,2000);
});
