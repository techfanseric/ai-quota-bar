// Every caller supplies a server-authenticated team. Request team IDs are never authority.
const json = (value, status = 200) => new Response(JSON.stringify(value), {status,
  headers: {'content-type': 'application/json', 'cache-control': 'no-store'}});
const text = (x, max = 200) => typeof x === 'string' && x.length <= max && !/[\u0000-\u001f]/.test(x);
export async function quotaAccounts(env, teamID) {
  return (await env.DB.prepare(`SELECT provider,account_key AS account_name,COUNT(*) sample_count,
    COUNT(DISTINCT model_id) model_count,MIN(sampled_at) earliest_sampled_at,MAX(sampled_at) latest_sampled_at
    FROM team_quota_samples WHERE team_id=? GROUP BY provider,account_key ORDER BY latest_sampled_at DESC LIMIT 1000`)
    .bind(teamID).all()).results;
}
export function auditStatement(env, teamID, actor, action, target) {
  return env.DB.prepare('INSERT INTO team_data_audit VALUES(?,?,?,?,?,?)')
    .bind(crypto.randomUUID(),teamID,actor,action,target,new Date().toISOString());
}
export async function deleteTeamQuota(env, teamID, actor, provider, account) {
  if (!text(provider) || !provider || !text(account)) return json({error:'invalid_account'},400);
  const result = await env.DB.batch([
    env.DB.prepare('DELETE FROM team_quota_heads WHERE team_id=? AND provider=? AND account_key=?').bind(teamID,provider,account),
    env.DB.prepare('DELETE FROM team_quota_samples WHERE team_id=? AND provider=? AND account_key=?').bind(teamID,provider,account),
    auditStatement(env,teamID,actor,'delete_quota_account',JSON.stringify({provider,account})),
  ]);
  return json({ok:true,deleted_quota_samples:result[1].meta.changes,deleted_devices:0,deleted_settings:0});
}
export async function teamQuota(request, env, url, who) {
  const team = who.team_id;
  if (url.pathname === '/v1/account-summaries' && request.method === 'GET')
    return json({ok:true,accounts:await quotaAccounts(env,team)});
  if (url.pathname === '/v1/devices' && request.method === 'GET') {
    const device = url.searchParams.get('device_id');
    const rows = await env.DB.prepare(`SELECT device_id AS id,member_name AS name,created_at,
      (SELECT MAX(sampled_at) FROM team_quota_heads q WHERE q.team_id=d.team_id AND q.device_id=d.device_id) last_seen_at
      FROM usage_devices d WHERE team_id=? ${device ? 'AND device_id=?' : ''}`)
      .bind(team,...(device ? [device] : [])).all();
    return json({ok:true,devices:rows.results.map(r=>({...r,last_seen_at:r.last_seen_at || r.created_at}))});
  }
  // Device credentials cannot perform account-wide deletion, including their own team's.
  if (request.method === 'DELETE') return json({error:'team_manager_required'},403);
  if (url.pathname !== '/v1/quota-samples') return json({error:'not_found'},404);
  if (request.method === 'GET') {
    const rawLimit = Number(url.searchParams.get('limit') || 100);
    if (!Number.isSafeInteger(rawLimit) || rawLimit < 1) return json({error:'invalid_limit'},400);
    const limit = Math.min(rawLimit,500), device = url.searchParams.get('device_id');
    const table = url.searchParams.get('history') === '1' ? 'team_quota_samples' : 'team_quota_heads';
    const scope = `team_id=? ${device ? 'AND device_id=?' : ''}`;
    // One latest snapshot per account/model: shared quota is not summed across devices.
    const sql = table === 'team_quota_heads' ? `SELECT payload FROM (
      SELECT payload,sampled_at,ROW_NUMBER() OVER(PARTITION BY provider,account_key,model_id ORDER BY sampled_at DESC,device_id) n
      FROM team_quota_heads WHERE ${scope}) WHERE n=1 ORDER BY sampled_at DESC LIMIT ?`
      : `SELECT payload FROM team_quota_samples WHERE ${scope} ORDER BY sampled_at DESC LIMIT ?`;
    const rows = await env.DB.prepare(sql).bind(team,...(device ? [device] : []),limit).all();
    return json({ok:true,samples:rows.results.map(r=>JSON.parse(r.payload))});
  }
  if (request.method !== 'POST') return json({error:'method_not_allowed'},405);
  let size=0, chunks=[];
  if (!request.body) return json({error:'invalid_payload'},400);
  for await (const chunk of request.body) { size+=chunk.length; if(size>262144) return json({error:'body_too_large'},413); chunks.push(chunk); }
  const bytes=new Uint8Array(size); let offset=0; for(const c of chunks){bytes.set(c,offset);offset+=c.length;}
  let p; try { p=JSON.parse(new TextDecoder().decode(bytes)); } catch { return json({error:'invalid_payload'},400); }
  if (!p || p.deviceID !== who.device_id || !Array.isArray(p.models) || p.models.length < 1 || p.models.length > 100
    || typeof p.sampledAt !== 'string' || !Number.isFinite(Date.parse(p.sampledAt))
    || Date.parse(p.sampledAt)>Date.now()+300000) return json({error:'invalid_payload'},400);
  const at=new Date(p.sampledAt).toISOString(), statements=[];
  for(const m of p.models) {
    if(!m || !text(m.provider) || !m.provider || !text(m.modelID) || !m.modelID || !text(m.modelName) || !m.modelName
      || !text(m.accountName ?? '')) return json({error:'invalid_model'},400);
    const values={};
    for(const [source,target] of [['currentIntervalTotal','current_interval_total'],['currentIntervalRemaining','current_interval_remaining'],['weeklyTotal','weekly_total'],['weeklyRemaining','weekly_remaining']]) {
      if(!Number.isSafeInteger(m[source]) || m[source]<0) return json({error:'invalid_quota'},400);
      values[target]=m[source];
    }
    if(m.currentIntervalRemainingPercent != null) {
      if(!Number.isInteger(m.currentIntervalRemainingPercent) || m.currentIntervalRemainingPercent<0 || m.currentIntervalRemainingPercent>100) return json({error:'invalid_quota'},400);
      values.current_interval_total=100; values.current_interval_remaining=m.currentIntervalRemainingPercent;
    }
    for(const [source,target] of [['resetStartTime','reset_start_time'],['resetEndTime','reset_end_time'],['weeklyStartTime','weekly_start_time'],['weeklyEndTime','weekly_end_time']]) {
      if(m[source]!=null && (typeof m[source]!=='string' || !Number.isFinite(Date.parse(m[source])))) return json({error:'invalid_date'},400);
      values[target]=m[source] ?? null;
    }
    if(!text(m.valueSuffix ?? '',40)) return json({error:'invalid_suffix'},400);
    const account=m.accountName ?? '';
    // Explicit allowlist: never persist caller credentials, arbitrary settings, or detail text.
    const payload=JSON.stringify({...values,device_id:who.device_id,provider:m.provider,account_name:account,
      model_id:m.modelID,model_name:m.modelName,value_suffix:m.currentIntervalRemainingPercent!=null?'%':m.valueSuffix??null,
      detail_text:null,sampled_at:at});
    const args=[team,who.device_id,m.provider,account,m.modelID,at,payload];
    statements.push(env.DB.prepare('INSERT OR IGNORE INTO team_quota_samples VALUES(?,?,?,?,?,?,?)').bind(...args));
    statements.push(env.DB.prepare(`INSERT INTO team_quota_heads VALUES(?,?,?,?,?,?,?)
      ON CONFLICT(team_id,device_id,provider,account_key,model_id) DO UPDATE SET sampled_at=excluded.sampled_at,payload=excluded.payload
      WHERE excluded.sampled_at>team_quota_heads.sampled_at`).bind(...args));
  }
  // Retention is server-owned, based on server time, and limited to this team.
  const cutoff=new Date(Date.now()-90*86400000).toISOString();
  statements.push(env.DB.prepare('DELETE FROM team_quota_samples WHERE team_id=? AND sampled_at<?').bind(team,cutoff));
  statements.push(env.DB.prepare('DELETE FROM team_quota_heads WHERE team_id=? AND sampled_at<?').bind(team,cutoff));
  await env.DB.batch(statements);
  return json({ok:true,inserted:p.models.length,retention_days:90});
}
