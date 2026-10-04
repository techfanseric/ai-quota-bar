// Cross-device Codex watch, outside the team system.
//
// A Mac that is signed in to a Codex account can publish that account's quota
// snapshot; any install that knows the address can then read it. No team, no invite
// code, no access key to type. The address itself is the lookup key, which means the
// read path is deliberately open to anyone who knows it -- the owner's per-account
// checkbox is the consent, and unchecking is the revocation.
//
// What crosses the wire is a projection: plan name, remaining percentages and reset
// times. Never credentials, never absolute token counts. `CodexAuthAccountStore`
// material is not reachable from this module at all.
//
// Authorization is the app-wide `SYNC_TOKEN`, which every install already carries.
// It ships inside the binary, so treat it as a speed bump that keeps casual `curl`
// out and gives reads an attribution bucket -- not as authentication. Do not widen
// it: nothing here may become a path to team data, device credentials or admin.
import { hitLimit } from './usage-team-core.js';

const MAX_BODY = 131072;
const MAX_ACCOUNTS = 20;
const MAX_WINDOWS = 8;
const MAX_NAME = 64;
const READ_LIMIT_PER_HOUR = 120;
const READS_LIMIT_PER_HOUR = 60;
const PUBLISH_LIMIT_PER_HOUR = 120;
// A publisher that stops reporting must not leave a snapshot that reads as current.
const STALE_AFTER_MS = 3 * 3600000;

const json = (value, status = 200, headers = {}) => new Response(JSON.stringify(value), {
  status, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...headers }
});

const normalizeAccount = value =>
  typeof value === 'string' ? value.trim().toLowerCase() : '';

// Deliberately stricter than the app's own check: this is an address used as a
// public lookup key, so anything that is not plainly an address is rejected rather
// than normalized into something surprising.
function accountKey(value) {
  const account = normalizeAccount(value);
  if (account.length < 3 || account.length > 254) return null;
  if (account.includes('..') || account.startsWith('.') || account.endsWith('.')) return null;
  const parts = account.split('@');
  if (parts.length !== 2) return null;
  const [local, domain] = parts;
  if (!local || local.length > 64 || !domain.includes('.')) return null;
  if (!/^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+$/.test(local)) return null;
  if (!/^[a-z0-9.-]+$/.test(domain)) return null;
  if (domain.split('.').some(part => !part || part.startsWith('-') || part.endsWith('-'))) return null;
  return account;
}

const digestKey = async account => {
  const bytes = new TextEncoder().encode(account);
  const hash = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(hash)].map(x => x.toString(16).padStart(2, '0')).join('');
};

const cleanName = value => {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'string') return undefined;
  const trimmed = value.trim();
  if (!trimmed) return null;
  if (trimmed.length > MAX_NAME || /[\u0000-\u001f]/.test(trimmed)) return undefined;
  return trimmed;
};

const cleanDate = value => {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'string' || !Number.isFinite(Date.parse(value))) return undefined;
  return new Date(value).toISOString();
};

function cleanWindow(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return undefined;
  // A window must be nameable. `plan` may legitimately be absent, but a nameless
  // window would render as an unlabelled quota bar on the reading Mac, so an empty
  // name is a malformed payload rather than an absent field.
  const name = raw.name === undefined || raw.name === null
    ? undefined
    : cleanName(raw.name);
  if (typeof name !== 'string') return undefined;
  const percent = raw.remainingPercent;
  // Percent is the only quota shape accepted: an absolute count would leak how much
  // this person actually burns, which the local UI never needs to share.
  if (!Number.isInteger(percent) || percent < 0 || percent > 100) return undefined;
  const resetsAt = cleanDate(raw.resetsAt);
  const sampledAt = cleanDate(raw.sampledAt);
  if (resetsAt === undefined || sampledAt === undefined) return undefined;
  return { name, remainingPercent: percent, resetsAt, sampledAt };
}

function cleanAccount(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return undefined;
  const account = accountKey(raw.account);
  if (!account) return undefined;
  const plan = cleanName(raw.plan);
  if (plan === undefined) return undefined;
  const windows = Array.isArray(raw.windows) ? raw.windows.slice(0, MAX_WINDOWS) : [];
  const cleaned = [];
  for (const window of windows) {
    const value = cleanWindow(window);
    if (value === undefined) return undefined;
    cleaned.push(value);
  }
  return { account, plan, windows: cleaned };
}

async function readBody(request) {
  if (!request.headers.get('content-type')?.startsWith('application/json') || !request.body) {
    throw new Error('invalid_body');
  }
  const reader = request.body.getReader();
  let length = 0; const chunks = [];
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    length += value.length;
    if (length > MAX_BODY) { await reader.cancel(); throw new Error('body_too_large'); }
    chunks.push(value);
  }
  const bytes = new Uint8Array(length); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  try { return JSON.parse(new TextDecoder().decode(bytes)); } catch { throw new Error('invalid_body'); }
}

// The app-wide key gates every route here. It is an ingestion-style gate, matching
// how SYNC_TOKEN is used for feedback: it proves the caller is an install of this
// app, nothing more.
function authorized(request, env) {
  if (!env.SYNC_TOKEN) return false;
  const auth = request.headers.get('authorization') || '';
  return auth.length <= 512 && auth === `Bearer ${env.SYNC_TOKEN}`;
}

const clientKey = request => request.headers.get('cf-connecting-ip') || 'local';

async function publish(request, env) {
  let payload;
  try { payload = await readBody(request); } catch (error) {
    return json({ error: error.message === 'body_too_large' ? 'body_too_large' : 'invalid_body' },
      error.message === 'body_too_large' ? 413 : 400);
  }
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return json({ error: 'invalid_payload' }, 400);
  const publisher = cleanName(payload.publisher);
  if (!publisher) return json({ error: 'invalid_publisher' }, 400);
  const raw = Array.isArray(payload.accounts) ? payload.accounts : null;
  if (raw === null || raw.length > MAX_ACCOUNTS) return json({ error: 'invalid_accounts' }, 400);

  const accounts = [];
  for (const entry of raw) {
    const value = cleanAccount(entry);
    if (value === undefined) return json({ error: 'invalid_account' }, 400);
    accounts.push(value);
  }
  // Two publishers claiming one address would leave the loser's un-share unable to
  // delete the row, so the second one is refused rather than silently overwriting.
  if (accounts.length) {
    const keys = [];
    for (const entry of accounts) keys.push(await digestKey(entry.account));
    const clash = await env.DB.prepare(
      `SELECT account_key FROM watch_shared_quota WHERE publisher_id<>? AND account_key IN (${keys.map(() => '?').join(',')}) LIMIT 1`)
      .bind(publisher, ...keys).all();
    if (clash.results.length) return json({ error: 'account_published_elsewhere' }, 409);
  }

  if (await hitLimit(env, `watch-pub|${publisher}`, 3600) > PUBLISH_LIMIT_PER_HOUR) {
    return json({ error: 'too_many_attempts' }, 429, { 'retry-after': '3600' });
  }

  const now = new Date().toISOString();
  // Replace-the-whole-set semantics: an empty `accounts` is how a user unshares
  // everything, so revocation does not need its own endpoint and cannot half-apply.
  const statements = [
    env.DB.prepare('DELETE FROM watch_shared_quota WHERE publisher_id=?').bind(publisher),
  ];
  for (const entry of accounts) {
    const key = await digestKey(entry.account);
    statements.push(env.DB.prepare(
      'INSERT INTO watch_shared_quota(account_key,publisher_id,payload,updated_at) VALUES(?,?,?,?)')
      .bind(key, publisher, JSON.stringify({ plan: entry.plan, windows: entry.windows, sampled_at: now }), now));
  }
  await env.DB.batch(statements);
  return json({ ok: true, published: accounts.length, updated_at: now });
}

async function quota(request, env, url) {
  const account = accountKey(url.searchParams.get('email') || '');
  if (!account) return json({ error: 'invalid_account' }, 400);
  if (await hitLimit(env, `watch-read|${clientKey(request)}`, 3600) > READ_LIMIT_PER_HOUR) {
    return json({ error: 'too_many_attempts' }, 429, { 'retry-after': '3600' });
  }
  const key = await digestKey(account);
  const rows = await env.DB.prepare('SELECT payload,updated_at FROM watch_shared_quota WHERE account_key=?').bind(key).all();
  const row = rows.results[0];
  // 404 is a real answer, not a soft failure: "nobody publishes this address" is the
  // single most common state and the client needs it verbatim to say so.
  if (!row) return json({ error: 'not_shared' }, 404);
  const age = Date.now() - Date.parse(row.updated_at);
  if (!Number.isFinite(age) || age > STALE_AFTER_MS) return json({ error: 'stale' }, 410);
  const now = new Date().toISOString();
  await env.DB.batch([
    env.DB.prepare(
      'INSERT INTO watch_reads(account_key,read_count,last_read_at) VALUES(?,1,?) ON CONFLICT(account_key) DO UPDATE SET read_count=read_count+1,last_read_at=excluded.last_read_at')
      .bind(key, now),
  ]);
  let parsed;
  try { parsed = JSON.parse(row.payload); } catch { return json({ error: 'invalid_stored_payload' }, 500); }
  return json({ ok: true, account, updated_at: row.updated_at, stale_after_ms: STALE_AFTER_MS, ...parsed });
}

async function reads(request, env, url) {
  const publisher = cleanName(url.searchParams.get('publisher') || '');
  if (!publisher) return json({ error: 'invalid_publisher' }, 400);
  if (await hitLimit(env, `watch-reads|${clientKey(request)}`, 3600) > READS_LIMIT_PER_HOUR) {
    return json({ error: 'too_many_attempts' }, 429, { 'retry-after': '3600' });
  }
  const rows = await env.DB.prepare(
    `SELECT s.account_key, s.updated_at, s.payload, r.read_count, r.last_read_at
     FROM watch_shared_quota s LEFT JOIN watch_reads r ON r.account_key=s.account_key
     WHERE s.publisher_id=? ORDER BY s.updated_at DESC`).bind(publisher).all();
  const accounts = [];
  for (const row of rows.results) {
    let plan = null;
    try { plan = JSON.parse(row.payload).plan ?? null; } catch { /* a corrupt row still reports its counters */ }
    accounts.push({
      account_key: row.account_key,
      plan,
      updated_at: row.updated_at,
      read_count: row.read_count || 0,
      last_read_at: row.last_read_at || null,
      stale: Date.now() - Date.parse(row.updated_at) > STALE_AFTER_MS,
    });
  }
  return json({ ok: true, accounts });
}

export async function codexWatchService(request, env, url) {
  if (!authorized(request, env)) return json({ error: 'unauthorized' }, 401);
  try {
    if (url.pathname === '/v1/watch/publish') {
      if (request.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
      return await publish(request, env);
    }
    if (url.pathname === '/v1/watch/quota') {
      if (request.method !== 'GET') return json({ error: 'method_not_allowed' }, 405);
      return await quota(request, env, url);
    }
    if (url.pathname === '/v1/watch/reads') {
      if (request.method !== 'GET') return json({ error: 'method_not_allowed' }, 405);
      return await reads(request, env, url);
    }
    return json({ error: 'not_found' }, 404);
  } catch (error) {
    if (error && /d1/i.test(String(error.message || error))) {
      return json({ error: 'service_unavailable' }, 503);
    }
    return json({ error: 'internal_error' }, 500);
  }
}

export const __testing = { accountKey, cleanAccount, cleanWindow, STALE_AFTER_MS };
