// Shared helpers for self-service teams: hashing, code generation and the
// fixed-window limiter backed by usage_team_limits. No routes live here.
const enc = new TextEncoder();

export const digest = async value => [...new Uint8Array(await crypto.subtle.digest('SHA-256', enc.encode(value)))].map(x => x.toString(16).padStart(2, '0')).join('');

// No I, L, O, 0 or 1: codes are read off a screen and retyped by hand.
const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
const codeGroup = length => Array.from(crypto.getRandomValues(new Uint32Array(length)), n => CODE_ALPHABET[n % CODE_ALPHABET.length]).join('');

export const teamsEnabled = env => env.USAGE_TEAMS_ENABLED === 'true';
export const newTeamID = () => 't' + crypto.randomUUID().replaceAll('-', '').slice(0, 16);
export const newMemberID = () => 'm' + crypto.randomUUID().replaceAll('-', '').slice(0, 16);
export const newInviteCode = () => [codeGroup(4), codeGroup(4), codeGroup(4)].join('-');
export const newLoginPassword = () => [codeGroup(5), codeGroup(5), codeGroup(5)].join('-');

// Accepts pasted codes with or without dashes, spaces or lowercase letters.
export const normalizeInvite = code => String(code ?? '').toUpperCase().replace(/[^A-Z2-9]/g, '');

export const inviteHash = async code => digest('aqb-invite|' + code);
export const loginHash = async password => digest('aqb-team-login|' + password);
export const memberPassHash = async (teamID, memberID, passphrase) => digest(`aqb-member|${teamID}|${memberID}|${passphrase}`);

// Fixed-window attempt counter. Records the attempt unconditionally and
// returns the incremented count; callers compare against their own maximum.
export async function hitLimit(env, bucket, windowSeconds) {
  const now = Math.floor(Date.now() / 1000);
  await env.DB.batch([
    env.DB.prepare('DELETE FROM usage_team_limits WHERE expires_at<?').bind(now),
    env.DB.prepare('INSERT INTO usage_team_limits(bucket,attempts,expires_at) VALUES(?,1,?) ON CONFLICT(bucket) DO UPDATE SET attempts=attempts+1').bind(bucket, now + windowSeconds),
  ]);
  const row = (await env.DB.prepare('SELECT attempts FROM usage_team_limits WHERE bucket=?').bind(bucket).all()).results[0];
  return row?.attempts || 1;
}

export async function clearLimit(env, ...buckets) {
  if (!buckets.length) return;
  await env.DB.batch(buckets.map(bucket => env.DB.prepare('DELETE FROM usage_team_limits WHERE bucket=?').bind(bucket)));
}

export function constantTimeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return difference === 0;
}
