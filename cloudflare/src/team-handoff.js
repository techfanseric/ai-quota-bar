import { identity } from './local-usage.js';
import { digest, loginHash, constantTimeEqual, hitLimit, clearLimit } from './usage-team-core.js';
const enc=new TextEncoder(),COOKIE='__Host-aqb_team';
const json=(body,status=200,headers={})=>new Response(JSON.stringify(body),{status,headers:{'content-type':'application/json','cache-control':'no-store',...headers}});
async function sign(value,key){const k=await crypto.subtle.importKey('raw',enc.encode(key),{name:'HMAC',hash:'SHA-256'},false,['sign']);return [...new Uint8Array(await crypto.subtle.sign('HMAC',k,enc.encode(value)))].map(v=>v.toString(16).padStart(2,'0')).join('');}
const tokenHash=request=>digest((request.headers.get('authorization')||'').slice(7));
export async function handoff(request,env,url,readBody){
 if(request.method!=='POST')return json({error:'method_not_allowed'},405);
 const origin=request.headers.get('origin');if(origin!==null&&origin!==url.origin)return json({error:'invalid_origin'},403);
 if(url.pathname.endsWith('/handoff')){
  const who=await identity(request,env);if(!who)return json({error:'unauthorized'},401);
  const p=await readBody(request);if(!p||typeof p!=='object'||Array.isArray(p))return json({error:'invalid_payload'},400);
  const team=(await env.DB.prepare('SELECT login_hash FROM usage_teams WHERE team_id=?').bind(who.team_id).all()).results[0];
  if(!team)return json({error:'team_console_unavailable'},409);
  if(Object.keys(p).some(k=>k!=='managementPassword'))return json({error:'invalid_payload'},400);
  let role='member';
  if(p.managementPassword!==undefined){
   if(typeof p.managementPassword!=='string'||p.managementPassword.length>200)return json({error:'invalid_credentials'},401);
   const bucket='handoff|'+who.team_id+'|'+(request.headers.get('cf-connecting-ip')||'local');
   if(await hitLimit(env,bucket,900)>10)return json({error:'too_many_attempts'},429);
   if(!constantTimeEqual(await loginHash(p.managementPassword),team.login_hash))return json({error:'invalid_credentials'},401);
   await clearLimit(env,bucket);role='manager';
  }
  const now=Math.floor(Date.now()/1000),ticket=crypto.randomUUID().replaceAll('-','')+crypto.randomUUID().replaceAll('-','');
  await env.DB.batch([
   env.DB.prepare('DELETE FROM team_browser_handoffs WHERE expires_at<=?').bind(now),
   env.DB.prepare('INSERT INTO team_browser_handoffs VALUES(?,?,?,?,?,?,?)').bind(await digest(ticket),who.team_id,role,who.device_id,await tokenHash(request),team.login_hash,now+120)
  ]);
  return json({ok:true,ticket,role,expiresIn:120});
 }
 // Browser redemption is same-origin and single-use, including failed/revoked redemptions.
 if(origin!==url.origin)return json({error:'invalid_origin'},403);
 const p=await readBody(request);if(!p||typeof p.ticket!=='string'||!/^[a-f0-9]{64}$/.test(p.ticket))return json({error:'invalid_ticket'},401);
 const row=(await env.DB.prepare('DELETE FROM team_browser_handoffs WHERE token_hash=? RETURNING *').bind(await digest(p.ticket)).all()).results[0];
 const now=Math.floor(Date.now()/1000);if(!row||row.expires_at<=now)return json({error:'expired_ticket'},401);
 const team=(await env.DB.prepare('SELECT login_hash FROM usage_teams WHERE team_id=?').bind(row.team_id).all()).results[0];
 const device=(await env.DB.prepare('SELECT member_id FROM usage_devices WHERE team_id=? AND device_id=? AND token_hash=? AND revoked=0').bind(row.team_id,row.device_id,row.device_token_hash).all()).results[0];
 if(!team||!device||!constantTimeEqual(team.login_hash,row.login_hash))return json({error:'revoked_ticket'},401);
 let value;
 if(row.role==='manager'){const raw=`${row.team_id}.${now+28800}.${crypto.randomUUID()}`;value=raw+'.'+await sign(raw,team.login_hash);}
 else {const raw=btoa(String.fromCharCode(...enc.encode(JSON.stringify({teamID:row.team_id,deviceID:row.device_id,tokenHash:row.device_token_hash,expiry:now+28800,nonce:crypto.randomUUID()})))).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'');value='member.'+raw+'.'+await sign(raw,team.login_hash);}
 return json({ok:true,role:row.role,teamID:row.team_id},200,{'set-cookie':`${COOKIE}=${value}; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=28800`});
}
export async function memberSession(cookie,env){
 try {
  if(cookie.length>1600)return null;const [prefix,raw,signature,...rest]=cookie.split('.');if(prefix!=='member'||rest.length||!raw||!signature)return null;
  const value=JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(raw.replaceAll('-','+').replaceAll('_','/')),c=>c.charCodeAt(0)))),now=Math.floor(Date.now()/1000);
  if(typeof value.teamID!=='string'||typeof value.deviceID!=='string'||typeof value.tokenHash!=='string'||!Number.isInteger(value.expiry)||value.expiry<=now||value.expiry>now+28800)return null;
  const team=(await env.DB.prepare('SELECT login_hash FROM usage_teams WHERE team_id=?').bind(value.teamID).all()).results[0];
  if(!team||!constantTimeEqual(signature,await sign(raw,team.login_hash)))return null;
  const device=(await env.DB.prepare('SELECT member_id FROM usage_devices WHERE team_id=? AND device_id=? AND token_hash=? AND revoked=0').bind(value.teamID,value.deviceID,value.tokenHash).all()).results[0];
  return device?{teamID:value.teamID,role:'member',memberID:device.member_id}:null;
 }catch{return null;}
}
