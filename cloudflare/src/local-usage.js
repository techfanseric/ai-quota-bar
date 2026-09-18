import { digest, teamsEnabled, hitLimit, clearLimit, constantTimeEqual, normalizeInvite, inviteHash, memberPassHash, newMemberID } from './usage-team-core.js';

const MAX_BODY = 512 * 1024;
const json = (body, status = 200, headers = {}) => new Response(JSON.stringify(body), { status,
  headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...headers } });
const text = (value, max = 120) => typeof value === 'string' && value.trim().length > 0 && value.length <= max && !/[\u0000-\u001f]/.test(value);
const date = value => typeof value === 'string' && /^\d{4}-\d{2}-\d{2}T/.test(value) && Number.isFinite(Date.parse(value));
async function body(request) {
  if (!request.body) throw new Error('invalid_body');
  const reader = request.body.getReader(); let bytes = 0; const chunks = [];
  try {
    while (true) {
      const { done, value } = await reader.read(); if (done) break;
      bytes += value.length;
      if (bytes > MAX_BODY) { await reader.cancel(); throw new Error('body_too_large'); }
      chunks.push(value);
    }
    const all = new Uint8Array(bytes); let offset = 0;
    for (const chunk of chunks) { all.set(chunk, offset); offset += chunk.length; }
    return JSON.parse(new TextDecoder().decode(all));
  } catch (error) { throw new Error(error.message === 'body_too_large' ? error.message : 'invalid_body'); }
}
export async function identity(request, env) {
  const auth = request.headers.get('authorization') || '';
  if (!auth.startsWith('Bearer ') || auth.length > 512) return null;
  const hash = await digest(auth.slice(7));
  const rows = await env.DB.prepare('SELECT d.team_id,d.member_id,d.member_name,d.device_id,t.team_name FROM usage_devices d LEFT JOIN usage_teams t ON t.team_id=d.team_id WHERE d.token_hash=? AND d.revoked=0').bind(hash).all();
  return rows.results[0] || null;
}
function validEvent(e) {
  if (!e || !/^[a-f0-9]{64}$/.test(e.id) || !date(e.occurredAt) || !text(e.model, 200)
    || !['exact', 'cumulative-delta'].includes(e.quality) || e.parserVersion !== 1
    || Date.parse(e.occurredAt) > Date.now() + 300_000) return false;
  if (e.accountID != null && (!/^[a-f0-9]{64}$/.test(e.accountID) || !['log', 'login-observation'].includes(e.accountSource))) return false;
  if (e.accountID == null && e.accountSource != null) return false;
  const t = e.tokens;
  return t && ['input', 'cached', 'cacheWrite', 'output', 'reasoning'].every(k => Number.isSafeInteger(t[k]) && t[k] >= 0 && t[k] <= 1e12)
    && t.cached + t.cacheWrite <= t.input && t.reasoning <= t.output && t.input + t.output > 0;
}
function cleanEvent(e) {
  return { id: e.id, occurredAt: new Date(e.occurredAt).toISOString(), model: e.model,
    tokens: { input: e.tokens.input, cached: e.tokens.cached, cacheWrite: e.tokens.cacheWrite, output: e.tokens.output, reasoning: e.tokens.reasoning },
    quality: e.quality, parserVersion: e.parserVersion, ...(e.accountID != null ? {accountID: e.accountID, accountSource: e.accountSource} : {}) };
}
function priceTable(env) {
  const prices = JSON.parse(env.USAGE_MODEL_PRICES || '[]');
  if (!Array.isArray(prices) || prices.length > 20) throw new Error('invalid_prices');
  for (const p of prices) {
    if (!text(p.model, 200) || !text(p.version) || !text(p.source, 1000) || !date(p.effectiveFrom)
      || (p.effectiveTo != null && (!date(p.effectiveTo) || Date.parse(p.effectiveTo) <= Date.parse(p.effectiveFrom)))
      || ![p.input, p.cached, p.output, p.cacheWrite ?? 0].every(n => typeof n === 'number' && Number.isFinite(n) && Number(n) >= 0 && Number(n) <= 1e6)) throw new Error('invalid_prices');
  }
  for (let i = 0; i < prices.length; i++) for (const b of prices.slice(i + 1)) {
    const a = prices[i];
    if (a.model === b.model && Date.parse(a.effectiveFrom) < (b.effectiveTo ? Date.parse(b.effectiveTo) : Infinity)
      && Date.parse(b.effectiveFrom) < (a.effectiveTo ? Date.parse(a.effectiveTo) : Infinity)) throw new Error('overlapping_prices');
  }
  return prices;
}

// Team-scoped aggregation shared by the device-facing summary endpoint and the
// /team dashboard. Splits aggregates by price interval, not individual
// requests, so the event ledger never loads into Worker memory.
export async function usageGroups(env, teamID, from, to, group, member = null) {
  const prices = priceTable(env);
  const clauses = []; const priceArgs = [];
  prices.forEach((p, index) => {
    clauses.push(`WHEN model=? AND occurred_at>=? AND occurred_at<? THEN ${index}`);
    priceArgs.push(p.model, new Date(p.effectiveFrom).toISOString(), p.effectiveTo ? new Date(p.effectiveTo).toISOString() : '9999-12-31T00:00:00.000Z');
  });
  const priceCase = clauses.length ? `(CASE ${clauses.join(' ')} ELSE -1 END)` : '-1';
  const dimension = { member: 'member_id', device: 'device_id', model: 'model', account: "COALESCE(account_id,'unknown')" }[group];
  const sql = `SELECT ${dimension} AS id, member_id, ${priceCase} AS price_index, COUNT(*) AS records,
    SUM(input_tokens) AS input, SUM(cached_tokens) AS cached, SUM(cache_write_tokens) AS cacheWrite,
    SUM(output_tokens) AS output, SUM(reasoning_tokens) AS reasoning,
    SUM(CASE WHEN quality<>'exact' THEN 1 ELSE 0 END) AS estimatedRecords,
    SUM(CASE WHEN cache_write_tokens>0 THEN 1 ELSE 0 END) AS writeRecords
    FROM usage_events WHERE team_id=? AND occurred_at>=? AND occurred_at<? ${member ? 'AND member_id=?' : ''}
    GROUP BY ${dimension},${group === 'device' ? 'member_id,' : ''}price_index,(cache_write_tokens>0)`;
  const result = await env.DB.prepare(sql).bind(...priceArgs, teamID, new Date(from).toISOString(), new Date(to).toISOString(), ...(member ? [member] : [])).all();
  const names = await env.DB.prepare('SELECT member_id,member_name FROM usage_members WHERE team_id=?').bind(teamID).all();
  const memberNames = new Map(names.results.map(x => [x.member_id, x.member_name]));
  const groups = new Map();
  for (const row of result.results) {
    const key = group === 'device' ? `${row.member_id}:${row.id}` : row.id;
    const item = groups.get(key) || { id: row.id, name: group === 'member' ? memberNames.get(row.id) || row.id : row.id,
      memberID: ['model','account'].includes(group) ? null : row.member_id, records: 0, input: 0, cached: 0, cacheWrite: 0, output: 0, reasoning: 0, estimatedRecords: 0, pricedRecords: 0, costUSD: 0 };
    for (const key of ['records','input','cached','cacheWrite','output','reasoning','estimatedRecords']) item[key] += row[key];
    const p = prices[row.price_index];
    if (p && (row.writeRecords === 0 || p.cacheWrite != null)) {
      const micro = Math.round((row.input-row.cached-row.cacheWrite)*Number(p.input) + row.cached*Number(p.cached)
        + row.cacheWrite*Number(p.cacheWrite || 0) + row.output*Number(p.output));
      if (Number.isSafeInteger(micro)) { item.costUSD += micro / 1e6; item.pricedRecords += row.records; }
    }
    item.cacheHitRate = item.input ? item.cached / item.input : null;
    groups.set(key, item);
  }
  return [...groups.values()].sort((a,b) => (b.input+b.output)-(a.input+a.output));
}

export async function localUsage(request, env, url) {
  try {
    if (url.pathname === '/v1/usage/devices' || url.pathname === '/v1/usage/devices/revoke') {
      // Never grant provisioning rights to the legacy app-wide SYNC_TOKEN.
      if (!env.USAGE_ADMIN_TOKEN || env.USAGE_ADMIN_TOKEN.length < 32 || env.USAGE_ADMIN_TOKEN === env.SYNC_TOKEN
        || request.headers.get('authorization') !== `Bearer ${env.USAGE_ADMIN_TOKEN}`) return json({ error: 'unauthorized' }, 401);
      if (request.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
      const p = await body(request);
      if (!text(p.teamID) || !text(p.deviceID)) return json({ error: 'invalid_identity' }, 400);
      if (url.pathname.endsWith('/revoke')) {
        await env.DB.prepare('UPDATE usage_devices SET revoked=1 WHERE team_id=? AND device_id=?').bind(p.teamID, p.deviceID).run();
        return json({ ok: true });
      }
      if (!text(p.memberID) || !text(p.memberName)) return json({ error: 'invalid_identity' }, 400);
      const existing = await env.DB.prepare('SELECT member_id FROM usage_devices WHERE team_id=? AND device_id=?').bind(p.teamID, p.deviceID).all();
      if (existing.results.length && existing.results[0].member_id !== p.memberID && p.reassign !== true) return json({ error: 'device_already_bound' }, 409);
      const token = `aqu_${crypto.randomUUID().replaceAll('-', '')}${crypto.randomUUID().replaceAll('-', '')}`;
      const writes = await env.DB.batch([env.DB.prepare(`INSERT INTO usage_devices(team_id,device_id,member_id,member_name,token_hash,created_at) VALUES(?,?,?,?,?,?)
        ON CONFLICT(team_id,device_id) DO UPDATE SET token_hash=excluded.token_hash,member_id=excluded.member_id,member_name=excluded.member_name,revoked=0
        WHERE usage_devices.member_id=excluded.member_id OR ?=1`)
        .bind(p.teamID, p.deviceID, p.memberID, p.memberName, await digest(token), new Date().toISOString(), p.reassign === true ? 1 : 0),
        env.DB.prepare(`INSERT INTO usage_members(team_id,member_id,member_name) VALUES(?,?,?)
          ON CONFLICT(team_id,member_id) DO UPDATE SET member_name=excluded.member_name`).bind(p.teamID,p.memberID,p.memberName)]);
      if (writes[0].meta.changes === 0) return json({ error: 'device_already_bound' }, 409);
      return json({ ok: true, token, identity: { team_id: p.teamID, device_id: p.deviceID, member_id: p.memberID, member_name: p.memberName } });
    }
    if (url.pathname === '/v1/usage/join') {
      // The invite code is the only credential; member identity stays
      // credential-bound afterwards, exactly like admin-provisioned devices.
      if (request.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
      if (!teamsEnabled(env)) return json({ error: 'teams_not_configured' }, 503);
      const p = await body(request);
      const code = normalizeInvite(p.inviteCode);
      const memberName = typeof p.memberName === 'string' ? p.memberName.trim() : '';
      const deviceID = typeof p.deviceID === 'string' ? p.deviceID.trim() : '';
      const passphrase = typeof p.memberPassphrase === 'string' ? p.memberPassphrase : '';
      if (code.length < 8 || code.length > 24) return json({ error: 'invalid_invite' }, 400);
      if (!text(memberName, 60) || !text(deviceID, 120)) return json({ error: 'invalid_identity' }, 400);
      if (passphrase && (passphrase.length < 4 || passphrase.length > 64)) return json({ error: 'invalid_passphrase' }, 400);
      const ipBucket = 'join-ip|' + (request.headers.get('cf-connecting-ip') || 'local');
      const codeBucket = 'join-code|' + (await inviteHash(code)).slice(0, 16);
      if (await hitLimit(env, ipBucket, 900) > 20 || await hitLimit(env, codeBucket, 900) > 30)
        return json({ error: 'too_many_attempts' }, 429, { 'retry-after': '900' });
      const team = (await env.DB.prepare('SELECT team_id FROM usage_teams WHERE invite_hash=?').bind(await inviteHash(code)).all()).results[0];
      if (!team) return json({ error: 'invalid_invite' }, 401);
      const teamID = team.team_id;
      const existingMember = (await env.DB.prepare('SELECT member_id FROM usage_members WHERE team_id=? AND member_name=?').bind(teamID, memberName).all()).results[0];
      const device = (await env.DB.prepare('SELECT member_id FROM usage_devices WHERE team_id=? AND device_id=?').bind(teamID, deviceID).all()).results[0];
      let memberID; let secretStatement = null;
      if (existingMember) {
        memberID = existingMember.member_id;
        // Device IDs are public identifiers. Rotation always requires the
        // current device credential or the member passphrase.
        {
          const secret = (await env.DB.prepare('SELECT pass_hash FROM usage_member_secrets WHERE team_id=? AND member_id=?').bind(teamID, memberID).all()).results[0];
          const current = await identity(request, env);
          const ownsDevice = current && current.team_id === teamID && current.device_id === deviceID && current.member_id === memberID;
          if (!secret && !ownsDevice) return json({ error: 'name_taken' }, 409);
          if (!ownsDevice && (!passphrase || !secret || !constantTimeEqual(await memberPassHash(teamID, memberID, passphrase), secret.pass_hash)))
            return json({ error: 'invalid_passphrase' }, 401);
        }
      } else {
        if (device) return json({ error: 'device_already_bound' }, 409);
        if (((await env.DB.prepare('SELECT COUNT(*) n FROM usage_members WHERE team_id=?').bind(teamID).all()).results[0] || {}).n >= 20)
          return json({ error: 'team_full' }, 403);
        memberID = newMemberID();
        if (passphrase) secretStatement = env.DB.prepare('INSERT INTO usage_member_secrets(team_id,member_id,pass_hash) VALUES(?,?,?)')
          .bind(teamID, memberID, await memberPassHash(teamID, memberID, passphrase));
      }
      const token = `aqu_${crypto.randomUUID().replaceAll('-', '')}${crypto.randomUUID().replaceAll('-', '')}`;
      await env.DB.batch([
        env.DB.prepare(`INSERT INTO usage_devices(team_id,device_id,member_id,member_name,token_hash,created_at) VALUES(?,?,?,?,?,?)
          ON CONFLICT(team_id,device_id) DO UPDATE SET token_hash=excluded.token_hash,member_id=excluded.member_id,member_name=excluded.member_name,revoked=0`)
          .bind(teamID, deviceID, memberID, memberName, await digest(token), new Date().toISOString()),
        env.DB.prepare(`INSERT INTO usage_members(team_id,member_id,member_name) VALUES(?,?,?)
          ON CONFLICT(team_id,member_id) DO UPDATE SET member_name=excluded.member_name`).bind(teamID, memberID, memberName),
        ...(secretStatement ? [secretStatement] : []),
      ]);
      await clearLimit(env, ipBucket, codeBucket);
      return json({ ok: true, token, identity: { team_id: teamID, device_id: deviceID, member_id: memberID, member_name: memberName } });
    }
    const who = await identity(request, env);
    if (!who) return json({ error: 'unauthorized' }, 401);
    if (url.pathname === '/v1/usage/leave' && request.method === 'POST') {
      await env.DB.prepare('UPDATE usage_devices SET revoked=1 WHERE team_id=? AND device_id=?').bind(who.team_id,who.device_id).run();
      return json({ok:true});
    }

    if (url.pathname === '/v1/usage/identity' && request.method === 'GET') return json({ ok: true, identity: who, prices: priceTable(env) });
    if (url.pathname === '/v1/usage/member/passphrase' && request.method === 'POST') {
      const p = await body(request);
      const passphrase = typeof p.passphrase === 'string' ? p.passphrase : '';
      if (passphrase.length < 4 || passphrase.length > 64) return json({ error: 'invalid_passphrase' }, 400);
      await env.DB.prepare(`INSERT INTO usage_member_secrets(team_id,member_id,pass_hash) VALUES(?,?,?)
        ON CONFLICT(team_id,member_id) DO UPDATE SET pass_hash=excluded.pass_hash`)
        .bind(who.team_id, who.member_id, await memberPassHash(who.team_id, who.member_id, passphrase)).run();
      return json({ ok: true });
    }
    if (url.pathname === '/v1/usage/events/batch' && request.method === 'POST') {
      const p = await body(request);
      if (!Array.isArray(p.events) || p.events.length < 1 || p.events.length > 50) return json({ error: 'invalid_batch' }, 400);
      const rejected = []; const events = []; const seen = new Set();
      for (const raw of p.events) {
        if (!validEvent(raw)) { rejected.push({ id: typeof raw?.id === 'string' ? raw.id.slice(0, 64) : '', reason: 'invalid_event' }); continue; }
        const e = cleanEvent(raw); const fingerprint = await digest(JSON.stringify(e));
        if (seen.has(e.id)) return json({ error: 'duplicate_id_in_batch' }, 400);
        seen.add(e.id); events.push({ ...e, fingerprint });
      }
      const statements = events.map(e => env.DB.prepare(`INSERT OR IGNORE INTO usage_events
        (team_id,event_id,device_id,member_id,occurred_at,model,input_tokens,cached_tokens,cache_write_tokens,output_tokens,reasoning_tokens,quality,parser_version,fingerprint,account_id,account_source)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).bind(who.team_id,e.id,who.device_id,who.member_id,e.occurredAt,e.model,
          e.tokens.input,e.tokens.cached,e.tokens.cacheWrite,e.tokens.output,e.tokens.reasoning,e.quality,e.parserVersion,e.fingerprint,e.accountID ?? null,e.accountSource ?? null));
      if (statements.length) await env.DB.batch(statements);
      const accepted = [];
      if (events.length) {
        const placeholders = events.map(() => '?').join(',');
        const saved = await env.DB.prepare(`SELECT event_id,member_id,fingerprint FROM usage_events WHERE team_id=? AND event_id IN (${placeholders})`)
          .bind(who.team_id, ...events.map(e => e.id)).all();
        const byID = new Map(saved.results.map(e => [e.event_id, e]));
        for (const e of events) {
          const old = byID.get(e.id);
          if (old?.member_id !== who.member_id) rejected.push({ id: e.id, reason: 'ownership_conflict' });
          else if (old.fingerprint !== e.fingerprint) rejected.push({ id: e.id, reason: 'content_conflict' });
          else accepted.push(e.id);
        }
      }
      return json({ ok: true, accepted, rejected });
    }
    if (url.pathname === '/v1/usage/summary' && request.method === 'GET') {
      const from = url.searchParams.get('from'); const to = url.searchParams.get('to');
      const group = url.searchParams.get('group_by') || 'member';
      if (!date(from) || !date(to) || Date.parse(to) <= Date.parse(from) || Date.parse(to) - Date.parse(from) > 366 * 86400_000
        || !['member', 'device', 'model', 'account'].includes(group)) return json({ error: 'invalid_range' }, 400);
      const member = url.searchParams.get('member_id');
      const groups = await usageGroups(env, who.team_id, from, to, group, member);
      return json({ ok: true, groups, from, to });
    }
    return json({ error: 'not_found' }, 404);
  } catch (error) {
    if (['invalid_body', 'body_too_large'].includes(error.message)) return json({ error: error.message }, error.message === 'body_too_large' ? 413 : 400);
    return json({ error: 'usage_service_unavailable' }, 503);
  }
}
