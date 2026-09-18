// Public feedback wall: submissions from the app (About tab) and the
// /feedback page share one D1 table. Contact details are private and are
// never returned by the public list endpoint, only by /v1/admin/feedback.
import { hitLimit } from './usage-team-core.js';

const MAX_BODY = 4096;
const MESSAGE_MAX = 1000;
const NICKNAME_MAX = 30;
const CONTACT_MAX = 120;
const SUBMIT_LIMIT_PER_HOUR = 5;
const LIST_DEFAULT = 20;
const LIST_MAX = 50;

const json = (value, status = 200, headers = {}) => new Response(JSON.stringify(value), { status, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...headers } });

const clean = value => {
  if (value === undefined) return '';
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  if (!trimmed) return '';
  // Single-line fields reject every control character.
  if (/[\u0000-\u001f]/.test(trimmed)) return null;
  return trimmed;
};

const cleanMessage = value => {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  // Messages allow newlines and tabs but no other control characters.
  if (!trimmed || trimmed.length > MESSAGE_MAX || /[\u0000-\u0008\u000b-\u001f]/.test(trimmed)) return null;
  return trimmed;
};

const versionField = (value, pattern) => {
  if (value === undefined) return '';
  return typeof value === 'string' && (value === '' || pattern.test(value)) ? value : null;
};

async function readBody(request) {
  if (!request.headers.get('content-type')?.startsWith('application/json') || !request.body) throw new Error('invalid_body');
  const reader = request.body.getReader(); let length = 0; const chunks = [];
  for (;;) { const { done, value } = await reader.read(); if (done) break; length += value.length; if (length > MAX_BODY) { await reader.cancel(); throw new Error('body_too_large'); } chunks.push(value); }
  const bytes = new Uint8Array(length); let offset = 0; for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  try { return JSON.parse(new TextDecoder().decode(bytes)); } catch { throw new Error('invalid_body'); }
}

function newFeedbackID() {
  return 'f' + [...crypto.getRandomValues(new Uint8Array(8))].map(x => x.toString(16).padStart(2, '0')).join('');
}

export async function feedbackService(request, env, url) {
  try {
    if (url.pathname === '/v1/feedback') {
      if (request.method === 'POST') return await submit(request, env, url);
      if (request.method === 'GET') return await listFeedback(env, url);
      return json({ error: 'method_not_allowed' }, 405);
    }
    return json({ error: 'not_found' }, 404);
  } catch (error) {
    if (['invalid_body', 'body_too_large'].includes(error.message)) return json({ error: error.message }, error.message === 'body_too_large' ? 413 : 400);
    return json({ error: 'feedback_service_unavailable' }, 503);
  }
}

async function submit(request, env, url) {
  // Browser submissions must be same-origin; native app submissions carry the
  // app-wide Bearer key, which is only an ingestion gate, never admin access.
  const origin = request.headers.get('origin');
  const fromBrowser = origin != null;
  if (fromBrowser) {
    if (origin !== url.origin) return json({ error: 'invalid_origin' }, 403);
  } else if (!env.SYNC_TOKEN || request.headers.get('authorization') !== `Bearer ${env.SYNC_TOKEN}`) {
    return json({ error: 'unauthorized' }, 401);
  }
  const p = await readBody(request);
  if (!p || typeof p !== 'object' || Array.isArray(p)
    || Object.keys(p).some(k => !['nickname', 'message', 'contact', 'appVersion', 'osVersion'].includes(k))) return json({ error: 'invalid_payload' }, 400);
  const nickname = clean(p.nickname);
  if (nickname === null || nickname.length > NICKNAME_MAX) return json({ error: 'invalid_nickname' }, 400);
  const contact = clean(p.contact);
  if (contact === null || contact.length > CONTACT_MAX) return json({ error: 'invalid_contact' }, 400);
  const message = cleanMessage(p.message);
  if (!message) return json({ error: 'invalid_message' }, 400);
  const appVersion = versionField(p.appVersion, /^\d{1,3}(\.\d{1,4}){0,3}([-.][a-zA-Z0-9]{1,12})?$/);
  if (appVersion === null) return json({ error: 'invalid_payload' }, 400);
  const osVersion = versionField(p.osVersion, /^\d{1,3}\.\d{1,3}$/);
  if (osVersion === null) return json({ error: 'invalid_payload' }, 400);
  const ip = request.headers.get('cf-connecting-ip') || 'local';
  if (await hitLimit(env, 'feedback-ip|' + ip, 3600) > SUBMIT_LIMIT_PER_HOUR) return json({ error: 'too_many_attempts' }, 429, { 'retry-after': '3600' });
  let id = newFeedbackID();
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      await env.DB.prepare('INSERT INTO feedback_messages(id,nickname,message,contact,source,app_version,os_version,status,created_at) VALUES(?,?,?,?,?,?,?,?,?)')
        .bind(id, nickname, message, contact, fromBrowser ? 'web' : 'app', appVersion, osVersion, 'published', new Date().toISOString()).run();
      return json({ ok: true, id });
    } catch (error) {
      if (!/UNIQUE constraint failed/.test(String(error.message))) throw error;
      id = newFeedbackID();
    }
  }
  return json({ error: 'feedback_service_unavailable' }, 503);
}

async function listFeedback(env, url) {
  const limitRaw = url.searchParams.get('limit');
  const offsetRaw = url.searchParams.get('offset');
  let limit = LIST_DEFAULT;
  if (limitRaw !== null) {
    if (!/^\d{1,3}$/.test(limitRaw) || Number(limitRaw) < 1 || Number(limitRaw) > LIST_MAX) return json({ error: 'invalid_limit' }, 400);
    limit = Number(limitRaw);
  }
  let offset = 0;
  if (offsetRaw !== null) {
    if (!/^\d{1,9}$/.test(offsetRaw)) return json({ error: 'invalid_offset' }, 400);
    offset = Number(offsetRaw);
  }
  const results = await env.DB.batch([
    env.DB.prepare('SELECT COUNT(*) total FROM feedback_messages WHERE status=?').bind('published'),
    env.DB.prepare('SELECT id,nickname,message,source,app_version,created_at FROM feedback_messages WHERE status=? ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?')
      .bind('published', limit, offset),
  ]);
  return json({
    ok: true,
    total: results[0].results[0]?.total || 0,
    items: results[1].results.map(row => ({ id: row.id, nickname: row.nickname, message: row.message, source: row.source, appVersion: row.app_version, createdAt: row.created_at })),
  });
}
