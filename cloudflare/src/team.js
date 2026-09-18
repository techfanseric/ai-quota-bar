import { handoff, memberSession } from './team-handoff.js';
import { quotaAccounts, deleteTeamQuota, auditStatement } from './team-quota.js';
// Self-service team console: /v1/team/create, login/logout and the cookie
// session that powers the /team dashboard. Sessions are signed with the
// team's stored login hash, so no global secret is shared between teams.
import { digest, teamsEnabled, hitLimit, clearLimit, constantTimeEqual, newTeamID, newInviteCode, newLoginPassword, inviteHash, loginHash } from './usage-team-core.js';
import { usageGroups } from './local-usage.js';

const enc = new TextEncoder();
const COOKIE = '__Host-aqb_team';
const SESSION_SECONDS = 28800;
const MAX_TEAM_MEMBERS = 20;

const json = (value, status = 200, headers = {}) => new Response(JSON.stringify(value), { status, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...headers } });
const text = (value, max) => typeof value === 'string' && value.trim().length > 0 && value.length <= max && !/[\u0000-\u001f]/.test(value);

async function readBody(request) {
  if (!request.headers.get('content-type')?.startsWith('application/json') || !request.body) throw new Error('invalid_body');
  const reader = request.body.getReader(); let length = 0; const chunks = [];
  for (;;) { const { done, value } = await reader.read(); if (done) break; length += value.length; if (length > 2048) { await reader.cancel(); throw new Error('body_too_large'); } chunks.push(value); }
  const bytes = new Uint8Array(length); let offset = 0; for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  try { return JSON.parse(new TextDecoder().decode(bytes)); } catch { throw new Error('invalid_body'); }
}

async function sign(value, key) {
  const imported = await crypto.subtle.importKey('raw', enc.encode(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return [...new Uint8Array(await crypto.subtle.sign('HMAC', imported, enc.encode(value)))].map(x => x.toString(16).padStart(2, '0')).join('');
}

async function sessionTeam(request, env) {
  const cookie = (request.headers.get('cookie') || '').split(';').map(x => x.trim()).find(x => x.startsWith(COOKIE + '='))?.slice(COOKIE.length + 1);
  if (cookie?.startsWith("member.")) return await memberSession(cookie,env);
  if (!cookie || cookie.length > 260) return null;
  const [teamID, expiry, nonce, signature, ...rest] = cookie.split('.');
  const now = Math.floor(Date.now() / 1000);
  if (rest.length || !/^t[a-f0-9]{16}$/.test(teamID) || !/^\d+$/.test(expiry) || !/^[-a-f0-9]{36}$/.test(nonce)
    || !Number.isSafeInteger(+expiry) || +expiry <= now || +expiry > now + SESSION_SECONDS) return null;
  const team = (await env.DB.prepare('SELECT login_hash FROM usage_teams WHERE team_id=?').bind(teamID).all()).results[0];
  if (!team) return null;
  return constantTimeEqual(signature, await sign(`${teamID}.${expiry}.${nonce}`, team.login_hash)) ? { teamID, role: "manager" } : null;
}

const sameOrigin = (request, url) => {
  const origin = request.headers.get('origin');
  return origin == null || origin === url.origin;
};

export async function teamService(request, env, url) {
  try {
    if (['/v1/team/handoff','/v1/team/redeem'].includes(url.pathname)) return await handoff(request,env,url,readBody);
    if (url.pathname === '/v1/team/create') {
      if (request.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
      if (!sameOrigin(request, url)) return json({ error: 'invalid_origin' }, 403);
      if (!teamsEnabled(env)) return json({ error: 'teams_not_configured' }, 503);
      const p = await readBody(request);
      const teamName = typeof p.teamName === 'string' ? p.teamName.trim() : '';
      if (!text(teamName, 60)) return json({ error: 'invalid_team_name' }, 400);
      const ip = request.headers.get('cf-connecting-ip') || 'local';
      if (await hitLimit(env, 'create-ip|' + ip, 3600) > 3) return json({ error: 'too_many_attempts' }, 429, { 'retry-after': '3600' });
      const inviteCode = newInviteCode();
      const loginPassword = newLoginPassword();
      let teamID = newTeamID();
      for (let attempt = 0; attempt < 3; attempt++) {
        try {
          await env.DB.prepare('INSERT INTO usage_teams(team_id,team_name,invite_hash,login_hash,invite_rotated_at,created_at) VALUES(?,?,?,?,?,?)')
            .bind(teamID, teamName, await inviteHash(inviteCode.replace(/-/g, '')), await loginHash(loginPassword), new Date().toISOString(), new Date().toISOString()).run();
          return json({ ok: true, teamID, teamName, inviteCode, loginPassword });
        } catch (error) {
          if (!/UNIQUE constraint failed/.test(String(error.message))) throw error;
          teamID = newTeamID();
        }
      }
      return json({ error: 'team_service_unavailable' }, 503);
    }
    if (url.pathname === '/v1/team/login') {
      if (request.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
      if (!sameOrigin(request, url)) return json({ error: 'invalid_origin' }, 403);
      if (!teamsEnabled(env)) return json({ error: 'teams_not_configured' }, 503);
      const p = await readBody(request);
      if (typeof p.teamID !== 'string' || !/^t[a-f0-9]{16}$/.test(p.teamID)
        || typeof p.password !== 'string' || p.password.length > 200) return json({ error: 'invalid_credentials' }, 401);
      const ip = request.headers.get('cf-connecting-ip') || 'local';
      const bucket = 'login|' + p.teamID + '|' + ip;
      if (await hitLimit(env, bucket, 900) > 10) return json({ error: 'too_many_attempts' }, 429, { 'retry-after': '900' });
      const team = (await env.DB.prepare('SELECT login_hash FROM usage_teams WHERE team_id=?').bind(p.teamID).all()).results[0];
      if (!team || !constantTimeEqual(await loginHash(p.password), team.login_hash)) return json({ error: 'invalid_credentials' }, 401);
      await clearLimit(env, bucket);
      const value = `${p.teamID}.${Math.floor(Date.now() / 1000) + SESSION_SECONDS}.${crypto.randomUUID()}`;
      return json({ ok: true }, 200, { 'set-cookie': `${COOKIE}=${value}.${await sign(value, team.login_hash)}; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=${SESSION_SECONDS}` });
    }
    if (url.pathname === '/v1/team/logout') {
      if (request.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
      if (!sameOrigin(request, url)) return json({ error: 'invalid_origin' }, 403);
      return json({ ok: true }, 200, { 'set-cookie': `${COOKIE}=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0` });
    }
    const session = await sessionTeam(request, env);
    if (!session) return json({ error: 'unauthorized' }, 401);
    const expectedTeam = request.headers.get('x-aqb-team');
    if (expectedTeam && expectedTeam !== session.teamID) return json({error:'team_session_changed'},409);
    if (session.role === 'member' && request.method !== 'GET') return json({error:'team_manager_required'},403);
    if (url.pathname === '/v1/team/accounts' && request.method === 'GET') return json({ok:true,accounts:await quotaAccounts(env,session.teamID)});
    if (url.pathname === '/v1/team/accounts' && request.method === 'DELETE') {
      if (!sameOrigin(request,url)) return json({error:'invalid_origin'},403);
      return await deleteTeamQuota(env,session.teamID,'team-manager',url.searchParams.get('provider'),url.searchParams.get('account_name'));
    }
    if (url.pathname === '/v1/team/members/revoke' && request.method === 'POST') {
      if (!sameOrigin(request,url)) return json({error:'invalid_origin'},403);
      const p=await readBody(request);
      if (!text(p.memberID,120)) return json({error:'invalid_identity'},400);
      await env.DB.batch([
        env.DB.prepare('UPDATE usage_devices SET revoked=1 WHERE team_id=? AND member_id=?').bind(session.teamID,p.memberID),
        auditStatement(env,session.teamID,'team-manager','revoke_member',p.memberID),
      ]);
      return json({ok:true});
    }
    if (request.method === 'GET' && url.pathname === '/v1/team/overview') return await overview(env, session.teamID, url, session);
    if (request.method === 'POST' && url.pathname === '/v1/team/invite/rotate') {
      if (!sameOrigin(request, url)) return json({ error: 'invalid_origin' }, 403);
      const inviteCode = newInviteCode();
      await env.DB.prepare('UPDATE usage_teams SET invite_hash=?,invite_rotated_at=? WHERE team_id=?')
        .bind(await inviteHash(inviteCode.replace(/-/g, '')), new Date().toISOString(), session.teamID).run();
      return json({ ok: true, inviteCode });
    }
    if (request.method === 'POST' && url.pathname === '/v1/team/devices/revoke') {
      if (!sameOrigin(request, url)) return json({ error: 'invalid_origin' }, 403);
      const p = await readBody(request);
      if (!text(p.deviceID, 120)) return json({ error: 'invalid_identity' }, 400);
      await env.DB.prepare('UPDATE usage_devices SET revoked=1 WHERE team_id=? AND device_id=?').bind(session.teamID, p.deviceID.trim()).run();
      return json({ ok: true });
    }
    return json({ error: 'not_found' }, 404);
  } catch (error) {
    if (['invalid_body', 'body_too_large'].includes(error.message)) return json({ error: error.message }, error.message === 'body_too_large' ? 413 : 400);
    return json({ error: 'team_service_unavailable' }, 503);
  }
}

async function overview(env, teamID, url, session) {
  const days = url.searchParams.get('days') || '30';
  if (!['7', '30', '90'].includes(days)) return json({ error: 'invalid_range' }, 400);
  const now = new Date();
  const today = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  const from = new Date(today - (Number(days) - 1) * 86400_000).toISOString();
  const to = new Date(today + 86400_000).toISOString();
  const results = await env.DB.batch([
    env.DB.prepare('SELECT team_id,team_name,created_at,invite_rotated_at FROM usage_teams WHERE team_id=?').bind(teamID),
    env.DB.prepare('SELECT member_id,member_name FROM usage_members WHERE team_id=?').bind(teamID),
    env.DB.prepare('SELECT device_id,member_id,revoked,created_at FROM usage_devices WHERE team_id=?').bind(teamID),
    env.DB.prepare('SELECT device_id,MAX(occurred_at) lastEventAt FROM usage_events WHERE team_id=? AND occurred_at>=? GROUP BY device_id').bind(teamID, from),
  ]);
  const team = results[0].results[0];
  if (!team) return json({ error: 'not_found' }, 404);
  const lastEvent = new Map(results[3].results.map(x => [x.device_id, x.lastEventAt]));
  const devicesByMember = new Map();
  for (const device of results[2].results) {
    if (!devicesByMember.has(device.member_id)) devicesByMember.set(device.member_id, []);
    devicesByMember.get(device.member_id).push({ deviceID: device.device_id, revoked: device.revoked === 1, createdAt: device.created_at, lastEventAt: lastEvent.get(device.device_id) || null });
  }
  const usage = {
    member: await usageGroups(env, teamID, from, to, 'member'),
    device: await usageGroups(env, teamID, from, to, 'device'),
    account: await usageGroups(env, teamID, from, to, 'account'),
  };
  return json({ ok: true, access: {role:session.role,canManage:session.role==='manager',memberID:session.memberID??null}, generatedAt: now.toISOString(), timezone: 'UTC', days, from, to,
    team: { teamID: team.team_id, teamName: team.team_name, createdAt: team.created_at, inviteRotatedAt: team.invite_rotated_at, memberLimit: MAX_TEAM_MEMBERS },
    members: results[1].results.map(m => ({ memberID: m.member_id, memberName: m.member_name, devices: devicesByMember.get(m.member_id) || [] })),
    usage });
}
