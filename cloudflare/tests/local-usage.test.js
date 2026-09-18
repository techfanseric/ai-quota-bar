import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import worker from '../src/worker.js';
const migration = readFileSync(new URL('../migrations/0002_local_usage.sql', import.meta.url), 'utf8');
const admin = 'test-administrator-token-at-least-32-characters';
function setup() {
  const db = new DatabaseSync(':memory:'); db.exec('PRAGMA foreign_keys=ON'); db.exec(migration); db.exec(migration); db.exec(readFileSync(new URL('../migrations/0003_usage_accounts.sql', import.meta.url), 'utf8'));
  const env = { USAGE_ADMIN_TOKEN: admin, SYNC_TOKEN: 'legacy-token', DB: {
    prepare(sql) { const statement = db.prepare(sql); let args = [];
      return { bind(...values) { args=values; return this; }, async all() { return {results:statement.all(...args)}; }, async run() { return {meta:{changes:Number(statement.run(...args).changes)}}; } }; },
    async batch(statements) { db.exec('BEGIN'); try { const values=[]; for(const s of statements) values.push(await s.run()); db.exec('COMMIT'); return values; } catch(error) { db.exec('ROLLBACK'); throw error; } }
  }}; return {db,env};
}
async function req(env,path,token,payload,status=200) {
  const r=await worker.fetch(new Request(`https://test.invalid${path}`,{method:payload===undefined?'GET':'POST',headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},body:payload===undefined?undefined:JSON.stringify(payload)}),env);
  const value=await r.json(); assert.equal(r.status,status,JSON.stringify(value)); return value;
}
async function register(env,deviceID='d1',memberID='alice',teamID='team') { return (await req(env,'/v1/usage/devices',admin,{deviceID,memberID,teamID,memberName:memberID})).token; }
const event=(n=1,model='fixture-model')=>({id:n.toString(16).padStart(64,'0'),occurredAt:'2026-01-02T12:00:00Z',model,tokens:{input:1000,cached:500,cacheWrite:100,output:100,reasoning:20},quality:'exact',parserVersion:1});
const range='/v1/usage/summary?from=2026-01-01T00:00:00Z&to=2026-02-01T00:00:00Z';
const price={model:'fixture-model',version:'v1',source:'fixture only',effectiveFrom:'2026-01-01T00:00:00Z',input:2,cached:1,cacheWrite:3,output:10};

test('device credentials are hashed, bound, rotatable and revocable; legacy token cannot provision',async()=>{
 const {db,env}=setup(); await req(env,'/v1/usage/devices','legacy-token',{teamID:'team',memberID:'alice',deviceID:'d1',memberName:'Alice'},401);
 const token=await register(env); assert.equal(db.prepare('SELECT token_hash FROM usage_devices').get().token_hash.length,64);
 assert.equal((await req(env,'/v1/usage/identity',token)).identity.member_id,'alice');
 await req(env,'/v1/usage/devices',admin,{teamID:'team',memberID:'bob',memberName:'Bob',deviceID:'d1'},409);
 const rotated=await register(env); await req(env,'/v1/usage/identity',token,undefined,401);
 await req(env,'/v1/usage/devices/revoke',admin,{teamID:'team',deviceID:'d1'}); await req(env,'/v1/usage/identity',rotated,undefined,401); db.close();
});
test('retries and copied logs count once; ownership conflicts are visible',async()=>{
 const {db,env}=setup(); const a=await register(env); const a2=await register(env,'d2'); const b=await register(env,'d3','bob'); const payload={events:[event()]};
 for(const token of [a,a,a2]) assert.equal((await req(env,'/v1/usage/events/batch',token,payload)).accepted.length,1);
 assert.equal((await req(env,'/v1/usage/events/batch',b,payload)).rejected[0].reason,'ownership_conflict');
 assert.equal(db.prepare('SELECT COUNT(*) n FROM usage_events').get().n,1); db.close();
});
test('untrusted identity cannot impersonate another member or team',async()=>{
 const {db,env}=setup(); const a=await register(env); const other=await register(env,'x','outsider','other-team');
 await req(env,'/v1/usage/events/batch',a,{teamID:'other-team',memberID:'bob',events:[event()]});
 assert.equal((await req(env,range,a)).groups[0].id,'alice'); assert.deepEqual((await req(env,range+'&team_id=team',other)).groups,[]);
 await req(env,'/v1/usage/events/batch',other,{events:[event()]}); assert.equal(db.prepare('SELECT COUNT(*) n FROM usage_events').get().n,2); db.close();
});
test('partial validation quarantines invalid counters and future events',async()=>{
 const {db,env}=setup(); const token=await register(env); const bad=event(2); bad.tokens.cached=1001; const neg=event(3); neg.tokens.input=-1; const future=event(4); future.occurredAt='2999-01-01T00:00:00Z';
 const response=await req(env,'/v1/usage/events/batch',token,{events:[event(),bad,neg,future]}); assert.deepEqual(response.accepted,[event().id]); assert.equal(response.rejected.length,3);
 assert.equal(db.prepare('SELECT COUNT(*) n FROM usage_events').get().n,1); db.close();
});
test('same ID with changed content never overwrites counted usage',async()=>{
 const {db,env}=setup(); const token=await register(env); await req(env,'/v1/usage/events/batch',token,{events:[event()]}); const changed=event(); changed.tokens.input=2000;
 assert.equal((await req(env,'/v1/usage/events/batch',token,{events:[changed]})).rejected[0].reason,'content_conflict'); assert.equal(db.prepare('SELECT input_tokens FROM usage_events').get().input_tokens,1000); db.close();
});
test('batch size, duplicate IDs, payload size and range are bounded',async()=>{
 const {db,env}=setup(); const token=await register(env);
 for(const events of [[],Array.from({length:51},(_,i)=>event(i+1)),[event(),event()]]) await req(env,'/v1/usage/events/batch',token,{events},400);
 await req(env,range+'&group_by=team_id',token,undefined,400); await req(env,'/v1/usage/summary?from=bad&to=bad',token,undefined,400);
 await req(env,'/v1/usage/events/batch',token,{padding:'x'.repeat(600000),events:[event()]},413); db.close();
});
test('weighted cache, dimensions, cost and exclusive end timestamp',async()=>{
 const {db,env}=setup(); env.USAGE_MODEL_PRICES=JSON.stringify([price]); const a=await register(env); const b=await register(env,'d2'); const second=event(2); second.tokens={input:9000,cached:0,cacheWrite:0,output:100,reasoning:0}; const outside=event(3); outside.occurredAt='2026-02-01T00:00:00Z';
 await req(env,'/v1/usage/events/batch',a,{events:[event(),outside]}); await req(env,'/v1/usage/events/batch',b,{events:[second]}); const r=(await req(env,range,a)).groups[0];
 assert.equal(r.records,2); assert.equal(r.input,10000); assert.equal(r.cacheHitRate,0.05); assert.equal(r.pricedRecords,2); assert.ok(Math.abs(r.costUSD-0.0216)<1e-10);
 assert.equal((await req(env,range+'&group_by=device',a)).groups.length,2); assert.equal((await req(env,range+'&group_by=model',a)).groups.length,1); assert.equal((await req(env,range+'&member_id=absent',a)).groups.length,0); db.close();
});
test('unknown models and missing write prices stay unpriced; late prices cover history',async()=>{
 const {db,env}=setup(); const token=await register(env); const noWrite=event(2); noWrite.tokens.cacheWrite=0;
 await req(env,'/v1/usage/events/batch',token,{events:[event(),noWrite,event(3,'unknown')]}); assert.equal((await req(env,range,token)).groups[0].pricedRecords,0);
 env.USAGE_MODEL_PRICES=JSON.stringify([{...price,cacheWrite:null}]); assert.equal((await req(env,range,token)).groups[0].pricedRecords,1);
 env.USAGE_MODEL_PRICES=JSON.stringify([price]); assert.equal((await req(env,range,token)).groups[0].pricedRecords,2); db.close();
});
test('historical prices use effective intervals, overlapping prices fail closed',async()=>{
 const {db,env}=setup(); const token=await register(env); const later=event(2); later.occurredAt='2026-01-15T00:00:00Z'; await req(env,'/v1/usage/events/batch',token,{events:[event(),later]});
 env.USAGE_MODEL_PRICES=JSON.stringify([{...price,effectiveTo:'2026-01-10T00:00:00Z'},{...price,version:'v2',effectiveFrom:'2026-01-10T00:00:00Z',input:4}]); assert.ok(Math.abs((await req(env,range,token)).groups[0].costUSD-0.006)<1e-10);
 env.USAGE_MODEL_PRICES=JSON.stringify([price,price]); await req(env,range,token,undefined,503); db.close();
});
test('failed transaction retries without loss or duplicate writes',async()=>{
 const {db,env}=setup(); const token=await register(env); const batch=env.DB.batch; env.DB.batch=async()=>{throw new Error('simulated outage');};
 await req(env,'/v1/usage/events/batch',token,{events:[event()]},503); assert.equal(db.prepare('SELECT COUNT(*) n FROM usage_events').get().n,0);
 env.DB.batch=batch; await req(env,'/v1/usage/events/batch',token,{events:[event()]}); assert.equal(db.prepare('SELECT COUNT(*) n FROM usage_events').get().n,1); db.close();
});
test('explicit member reassignment preserves historical ownership and rotates credentials',async()=>{
 const {db,env}=setup(); const alice=await register(env); await req(env,'/v1/usage/events/batch',alice,{events:[event()]});
 const bob=(await req(env,'/v1/usage/devices',admin,{teamID:'team',deviceID:'d1',memberID:'bob',memberName:'Bob',reassign:true})).token;
 await req(env,'/v1/usage/identity',alice,undefined,401); await req(env,'/v1/usage/events/batch',bob,{events:[event(2)]});
 const rows=(await req(env,range,bob)).groups; assert.equal(rows.length,2); assert.equal(rows.find(r=>r.id==='alice').name,'alice');
 const devices=(await req(env,range+'&group_by=device',bob)).groups; assert.equal(devices.length,2); assert.deepEqual(new Set(devices.map(d=>d.memberID)),new Set(['alice','bob'])); db.close();
});

test('account dimension preserves unknown history and separates account switches', async()=>{
 const {db,env}=setup(); const token=await register(env);
 const a={...event(1),accountID:'a'.repeat(64),accountSource:'login-observation'};
 const b={...event(2),accountID:'b'.repeat(64),accountSource:'log'};
 const old=event(3);
 await req(env,'/v1/usage/events/batch',token,{events:[a,b,old]});
 const groups=(await req(env,range+'&group_by=account',token)).groups;
 assert.deepEqual(groups.map(x=>x.id).sort(),['a'.repeat(64),'b'.repeat(64),'unknown']);
 assert.equal(groups.reduce((sum,x)=>sum+x.records,0),3);
 const changed={...old,accountID:'a'.repeat(64),accountSource:'login-observation'};
 assert.equal((await req(env,'/v1/usage/events/batch',token,{events:[changed]})).rejected[0].reason,'content_conflict');
 assert.equal((await req(env,'/v1/usage/events/batch',token,{events:[old]})).accepted.length,1);
 await req(env,'/v1/usage/events/batch',token,{events:[{...event(4),accountID:'email@example.com',accountSource:'log'}]}).then(r=>assert.equal(r.rejected[0].reason,'invalid_event'));
 db.close();
});
