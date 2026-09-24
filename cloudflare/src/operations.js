import { TEAM_COOKIE } from './team.js';
const enc = new TextEncoder();
const COOKIE = '__Host-aqb_ops';
const json = (value,status=200,headers={}) => new Response(JSON.stringify(value), {status,headers:{'content-type':'application/json; charset=utf-8','cache-control':'no-store',...headers}});
const hash = async text => [...new Uint8Array(await crypto.subtle.digest('SHA-256',enc.encode(text)))].map(x=>x.toString(16).padStart(2,'0')).join('');
async function readBody(request) {
  if(!request.headers.get('content-type')?.startsWith('application/json') || !request.body) throw new Error('invalid_body');
  const reader=request.body.getReader();let length=0;const chunks=[];
  for(;;){const {done,value}=await reader.read();if(done)break;length+=value.length;if(length>2048){await reader.cancel();throw new Error('body_too_large');}chunks.push(value);}
  const bytes=new Uint8Array(length);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
  try{return JSON.parse(new TextDecoder().decode(bytes));}catch{throw new Error('invalid_body');}
}
const secretReady = env => typeof env.OPS_ADMIN_SECRET==='string' && env.OPS_ADMIN_SECRET.length>=40 && env.OPS_ADMIN_SECRET!==env.SYNC_TOKEN;
async function sign(value,secret) {
 const key=await crypto.subtle.importKey('raw',enc.encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);
 return [...new Uint8Array(await crypto.subtle.sign('HMAC',key,enc.encode(value)))].map(x=>x.toString(16).padStart(2,'0')).join('');
}
function equal(a,b){if(typeof a!=='string'||typeof b!=='string'||a.length!==b.length)return false;let d=0;for(let i=0;i<a.length;i++)d|=a.charCodeAt(i)^b.charCodeAt(i);return d===0;}
export async function authorized(request,env) {
 if(!secretReady(env))return false;
 const cookie=(request.headers.get('cookie')||'').split(';').map(x=>x.trim()).find(x=>x.startsWith(COOKIE+'='))?.slice(COOKIE.length+1);
 if(!cookie||cookie.length>220)return false;
 const [expiry,nonce,signature,...rest]=cookie.split('.');const now=Math.floor(Date.now()/1000);
 if(rest.length||!/^\d+$/.test(expiry)||!/^[-a-f0-9]{36}$/.test(nonce)||!Number.isSafeInteger(+expiry)||+expiry<=now||+expiry>now+28800)return false;
 return equal(signature,await sign(expiry+'.'+nonce,env.OPS_ADMIN_SECRET));
}
export async function operations(request,env,url) {
 try {
  if(url.pathname.startsWith('/v1/telemetry/'))return await telemetry(request,env,url);
  if(url.pathname==='/v1/admin/login') {
   if(request.method!=='POST')return json({error:'method_not_allowed'},405);
   if(request.headers.get('origin')!==url.origin)return json({error:'invalid_origin'},403);
   if(!secretReady(env))return json({error:'admin_not_configured'},503);
   const p=await readBody(request);
   if(typeof p.password!=='string'||p.password.length>200)return json({error:'invalid_credentials'},401);
   const now=Math.floor(Date.now()/1000);const bucket=await hash(env.OPS_ADMIN_SECRET+'|'+(request.headers.get('cf-connecting-ip')||'local')+'|'+Math.floor(now/900));
   await env.DB.batch([
    env.DB.prepare('DELETE FROM ops_login_limits WHERE expires_at<?').bind(now),
    env.DB.prepare('INSERT INTO ops_login_limits(bucket,attempts,expires_at) VALUES(?,1,?) ON CONFLICT(bucket) DO UPDATE SET attempts=attempts+1').bind(bucket,now+900),
   ]);
   const count=(await env.DB.prepare('SELECT attempts FROM ops_login_limits WHERE bucket=?').bind(bucket).all()).results[0]?.attempts||0;
   if(count>10)return json({error:'too_many_attempts'},429,{'retry-after':'900'});
   if(!equal(await hash(p.password),await hash(env.OPS_ADMIN_SECRET)))return json({error:'invalid_credentials'},401);
   await env.DB.prepare('DELETE FROM ops_login_limits WHERE bucket=?').bind(bucket).run();
   const value=(now+28800)+'.'+crypto.randomUUID();
   return json({ok:true},200,{'set-cookie':COOKIE+'='+value+'.'+await sign(value,env.OPS_ADMIN_SECRET)+'; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=28800'});
  }
  if(url.pathname==='/v1/admin/logout') {
   if(request.method!=='POST')return json({error:'method_not_allowed'},405);
   if(request.headers.get('origin')!==url.origin)return json({error:'invalid_origin'},403);
   return json({ok:true},200,{'set-cookie':COOKIE+'=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0'});
  }
  if(!await authorized(request,env))return json({error:'unauthorized'},401);
  // Passwordless team access for the platform admin: swap the browser's team
  // cookie for one signed with OPS_ADMIN_SECRET (accepted by team.js as a
  // manager session). The team's own login password is never touched.
  if(url.pathname==='/v1/admin/team-session') {
   if(request.method!=='POST')return json({error:'method_not_allowed'},405);
   if(request.headers.get('origin')!==url.origin)return json({error:'invalid_origin'},403);
   const p=await readBody(request);
   const teamID=typeof p.teamID==='string'?p.teamID:'';
   if(!/^[a-z0-9_-]{1,60}$/.test(teamID))return json({error:'invalid_team'},400);
   const known=(await env.DB.prepare('SELECT team_id FROM usage_teams WHERE team_id=? UNION ALL SELECT team_id FROM usage_devices WHERE team_id=? LIMIT 1').bind(teamID,teamID).all()).results[0];
   if(!known)return json({error:'not_found'},404);
   const value=`admin.${teamID}.${Math.floor(Date.now()/1000)+28800}.${crypto.randomUUID()}`;
   return json({ok:true,teamID},200,{'set-cookie':TEAM_COOKIE+'='+value+'.'+await sign(value,env.OPS_ADMIN_SECRET)+'; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=28800'});
  }
  if(request.method==='GET'&&url.pathname==='/v1/admin/overview')return await overview(env,url);
  if(request.method==='GET'&&url.pathname==='/v1/admin/feedback')return await feedbackList(env,url);
  if(request.method==='POST'&&url.pathname==='/v1/admin/feedback/status') {
   if(request.headers.get('origin')!==null&&request.headers.get('origin')!==url.origin)return json({error:'invalid_origin'},403);
   const p=await readBody(request);
   if(!p||typeof p!=='object'||Object.keys(p).some(k=>!['id','status'].includes(k))
     ||typeof p.id!=='string'||!/^f[a-f0-9]{16}$/.test(p.id)
     ||!['published','hidden'].includes(p.status))return json({error:'invalid_payload'},400);
   await env.DB.prepare('UPDATE feedback_messages SET status=? WHERE id=?').bind(p.status,p.id).run();
   return json({ok:true});
  }
  if(request.method==='DELETE'&&url.pathname==='/v1/admin/feedback') {
   if(request.headers.get('origin')!==null&&request.headers.get('origin')!==url.origin)return json({error:'invalid_origin'},403);
   const id=url.searchParams.get('id');
   if(typeof id!=='string'||!/^f[a-f0-9]{16}$/.test(id))return json({error:'invalid_payload'},400);
   await env.DB.prepare('DELETE FROM feedback_messages WHERE id=?').bind(id).run();
   return json({ok:true});
  }
  return json({error:'not_found'},404);
 }catch(e){if(['invalid_body','body_too_large'].includes(e.message))return json({error:e.message},e.message==='body_too_large'?413:400);return json({error:'operations_unavailable'},503);}
}
async function telemetry(request,env,url) {
 if(request.method!=='POST')return json({error:'method_not_allowed'},405);
 // This app-wide key is only an ingestion gate, never administrator access.
 if(!env.SYNC_TOKEN||request.headers.get('authorization')!==`Bearer ${env.SYNC_TOKEN}`)return json({error:'unauthorized'},401);
 if(!['/v1/telemetry/pulse','/v1/telemetry/forget'].includes(url.pathname))return json({error:'not_found'},404);
 const p=await readBody(request);
 if(!p||typeof p.installationToken!=='string'||!/^[a-f0-9]{64}$/.test(p.installationToken))return json({error:'invalid_installation'},400);
 const id=await hash('aqb-telemetry|'+p.installationToken);
 if(url.pathname.endsWith('/forget')){
  await env.DB.batch([env.DB.prepare('INSERT OR IGNORE INTO telemetry_revocations(id) VALUES(?)').bind(id),env.DB.prepare('DELETE FROM telemetry_days WHERE install_id=?').bind(id),env.DB.prepare('DELETE FROM telemetry_installs WHERE id=?').bind(id)]);
  return json({ok:true});
 }
 if((await env.DB.prepare('SELECT id FROM telemetry_revocations WHERE id=?').bind(id).all()).results.length)return json({error:'installation_deleted'},410);
 if(Object.keys(p).some(k=>!['installationToken','event','appVersion','appBuild','osVersion'].includes(k))
   ||!['active','heartbeat'].includes(p.event)||!/^\d{1,3}(\.\d{1,4}){0,3}([-.][a-zA-Z0-9]{1,12})?$/.test(p.appVersion||'')
   ||!/^\d{1,10}$/.test(p.appBuild||'')||!/^\d{1,3}\.\d{1,3}$/.test(p.osVersion||''))return json({error:'invalid_payload'},400);
 const now=new Date(),at=now.toISOString(),day=at.slice(0,10),cutoff=new Date(now-89*86400000).toISOString().slice(0,10);
 const beforeHour=new Date(now-3600000).toISOString();
 await env.DB.batch([
  env.DB.prepare(`INSERT INTO telemetry_installs(id,first_seen_at,last_seen_at,app_version,app_build,os_version) SELECT ?,?,?,?,?,? WHERE NOT EXISTS(SELECT 1 FROM telemetry_revocations WHERE id=?)
   ON CONFLICT(id) DO UPDATE SET last_seen_at=excluded.last_seen_at,app_version=excluded.app_version,app_build=excluded.app_build,os_version=excluded.os_version
   WHERE telemetry_installs.last_seen_at<=? OR telemetry_installs.app_version<>excluded.app_version OR telemetry_installs.app_build<>excluded.app_build`)
   .bind(id,at,at,p.appVersion,p.appBuild,p.osVersion,id,beforeHour),
  env.DB.prepare(`INSERT INTO telemetry_days(day,install_id,active) SELECT ?,?,? WHERE EXISTS(SELECT 1 FROM telemetry_installs WHERE id=?) ON CONFLICT(day,install_id) DO UPDATE SET active=1 WHERE excluded.active=1 AND telemetry_days.active=0`).bind(day,id,p.event==='active'?1:0,id),
  env.DB.prepare('DELETE FROM telemetry_days WHERE day<?').bind(cutoff),
 ]);
 return json({ok:true});
}
async function feedbackList(env,url) {
 const limitRaw=url.searchParams.get('limit')||'50';
 if(!/^\d{1,3}$/.test(limitRaw)||Number(limitRaw)<1||Number(limitRaw)>200)return json({error:'invalid_limit'},400);
 const results=await env.DB.batch([
  env.DB.prepare('SELECT status,COUNT(*) count FROM feedback_messages GROUP BY status'),
  env.DB.prepare('SELECT id,nickname,message,contact,source,app_version,os_version,status,created_at FROM feedback_messages ORDER BY created_at DESC, id DESC LIMIT ?').bind(Number(limitRaw)),
 ]);
 const counts={published:0,hidden:0};
 for(const row of results[0].results)counts[row.status]=row.count;
 return json({ok:true,counts,items:results[1].results.map(row=>({id:row.id,nickname:row.nickname,message:row.message,contact:row.contact,source:row.source,appVersion:row.app_version,osVersion:row.os_version,status:row.status,createdAt:row.created_at}))});
}
async function overview(env,url) {
 const raw=url.searchParams.get('days')||'30';if(!['7','30','90'].includes(raw))return json({error:'invalid_range'},400);
 const days=Number(raw),now=new Date(),today=now.toISOString().slice(0,10);
 const start=n=>new Date(Date.UTC(now.getUTCFullYear(),now.getUTCMonth(),now.getUTCDate()-(n-1))).toISOString().slice(0,10);
 const from=start(days);
 const results=await env.DB.batch([
  env.DB.prepare(`SELECT COUNT(*) total,COALESCE(SUM(first_seen_at>=?),0) new_today,COALESCE(SUM(last_seen_at>=?),0) reporting_recently,COALESCE(SUM(last_seen_at>=?),0) reporting_month FROM telemetry_installs`).bind(today,new Date(now-2*3600000).toISOString(),start(30)),
  env.DB.prepare(`SELECT COUNT(DISTINCT CASE WHEN day=? THEN install_id END) dau,COUNT(DISTINCT CASE WHEN day>=? THEN install_id END) wau,COUNT(DISTINCT install_id) mau FROM telemetry_days WHERE active=1 AND day>=?`).bind(today,start(7),start(30)),
  env.DB.prepare(`SELECT day,COUNT(*) active FROM telemetry_days WHERE active=1 AND day>=? GROUP BY day ORDER BY day`).bind(from),
  env.DB.prepare(`SELECT substr(first_seen_at,1,10) day,COUNT(*) new_installs FROM telemetry_installs WHERE first_seen_at>=? GROUP BY day ORDER BY day`).bind(from),
  env.DB.prepare(`SELECT app_version version,app_build build,COUNT(*) installs FROM telemetry_installs WHERE last_seen_at>=? GROUP BY app_version,app_build ORDER BY installs DESC LIMIT 20`).bind(start(30)),
  env.DB.prepare(`SELECT os_version version,COUNT(*) installs FROM telemetry_installs WHERE last_seen_at>=? GROUP BY os_version ORDER BY installs DESC LIMIT 20`).bind(start(30)),
  env.DB.prepare(`SELECT COUNT(*) count FROM devices`),
  env.DB.prepare(`SELECT COUNT(*) count FROM usage_members`),
  env.DB.prepare(`SELECT MIN(first_seen_at) since FROM telemetry_installs`),
 ]);
 const first=i=>results[i].results[0]||{};
 const active=new Map(results[2].results.map(x=>[x.day,x.active]));const fresh=new Map(results[3].results.map(x=>[x.day,x.new_installs]));
 const trend=Array.from({length:days},(_,index)=>{const day=start(days-index);return {day,active:active.get(day)||0,newInstalls:fresh.get(day)||0};});
 return json({ok:true,generatedAt:now.toISOString(),timezone:'UTC',days,coverageSince:first(8).since||null,
  metrics:{...first(0),...first(1)},trend,versions:results[4].results,systems:results[5].results,
  legacy:{syncedDevices:first(6).count||0,configuredMembers:first(7).count||0}});
}
