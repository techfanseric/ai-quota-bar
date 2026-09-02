export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url);

      if (request.method === "OPTIONS") {
        return cors(new Response(null, { status: 204 }));
      }

      if (request.method === "GET" && url.pathname === "/v1/app-update") {
        return await appUpdateManifest(env);
      }

      if (!isAuthorized(request, env)) {
        return json({ error: "unauthorized" }, 401);
      }

      if (request.method === "GET" && url.pathname === "/v1/health") {
        return json({ ok: true });
      }

      if (request.method === "POST" && url.pathname === "/v1/quota-samples") {
        return await storeQuotaSamples(request, env);
      }

      if (request.method === "GET" && url.pathname === "/v1/quota-samples") {
        return await listQuotaSamples(url, env);
      }

      if (request.method === "GET" && url.pathname === "/v1/account-summaries") {
        return await listAccountSummaries(url, env);
      }

      if (request.method === "GET" && url.pathname === "/v1/devices") {
        return await listDevices(url, env);
      }

      if (request.method === "DELETE" && url.pathname === "/v1/data") {
        return await deleteDeviceData(url, env);
      }

      return json({ error: "not_found" }, 404);
    } catch (error) {
      return json({ error: "internal_error", message: error.message }, 500);
    }
  },
};

async function appUpdateManifest(env) {
  const fallbackVersion = env.APP_LATEST_VERSION || "1.4.2";
  const fallbackURL = env.APP_RELEASE_URL || `https://github.com/techfanseric/ai-quota-bar/releases/tag/v${fallbackVersion}`;
  const fallbackDownloadURL = env.APP_DOWNLOAD_URL || `https://github.com/techfanseric/ai-quota-bar/releases/download/v${fallbackVersion}/AIQuotaBar.dmg`;

  try {
    const response = await fetch("https://api.github.com/repos/techfanseric/ai-quota-bar/releases/latest", {
      headers: {
        accept: "application/vnd.github+json",
        "user-agent": "AIQuotaBar-UpdateProxy",
      },
      cf: {
        cacheTtl: 300,
        cacheEverything: true,
      },
    });

    if (!response.ok) {
      throw new Error(`github_${response.status}`);
    }

    const release = await response.json();
    const version = normalizeVersion(release.tag_name || fallbackVersion);
    const asset = Array.isArray(release.assets)
      ? release.assets.find((item) => item && item.name === "AIQuotaBar.dmg")
      : null;

    return json({
      ok: true,
      source: "github-proxy",
      version,
      tag: release.tag_name || `v${version}`,
      release_url: release.html_url || fallbackURL,
      download_url: asset?.browser_download_url || fallbackDownloadURL,
      published_at: release.published_at || null,
    });
  } catch (error) {
    return json({
      ok: true,
      source: "worker-fallback",
      version: normalizeVersion(fallbackVersion),
      tag: `v${normalizeVersion(fallbackVersion)}`,
      release_url: fallbackURL,
      download_url: fallbackDownloadURL,
      warning: error.message,
    });
  }
}

function normalizeVersion(value) {
  const version = stringValue(value);
  return version.toLowerCase().startsWith("v") ? version.slice(1) : version;
}

function isAuthorized(request, env) {
  const expected = env.SYNC_TOKEN || "";
  const header = request.headers.get("authorization") || "";
  return expected.length > 0 && header === `Bearer ${expected}`;
}

async function storeQuotaSamples(request, env) {
  const payload = await request.json();
  const deviceID = String(payload.deviceID || "").trim();
  const sampledAt = String(payload.sampledAt || "").trim();
  const models = Array.isArray(payload.models) ? payload.models : [];
  const retentionDays = retentionDaysValue(payload.retentionDays);

  if (!deviceID || !sampledAt || models.length === 0) {
    return json({ error: "invalid_payload" }, 400);
  }

  const statements = [
    env.DB.prepare(
      `INSERT INTO devices (id, last_seen_at)
       VALUES (?, ?)
       ON CONFLICT(id) DO UPDATE SET last_seen_at = excluded.last_seen_at
       WHERE devices.last_seen_at IS NOT excluded.last_seen_at`
    ).bind(deviceID, sampledAt),
  ];

  for (const model of models) {
    const provider = stringValue(model.provider);
    const modelID = stringValue(model.modelID);
    const modelName = stringValue(model.modelName);

    if (!provider || !modelID || !modelName) {
      continue;
    }

    const currentRemainingPercent = nullableInteger(model.currentIntervalRemainingPercent);
    const storedCurrentTotal = currentRemainingPercent === null
      ? integerValue(model.currentIntervalTotal)
      : 100;
    const storedCurrentRemaining = currentRemainingPercent === null
      ? integerValue(model.currentIntervalRemaining)
      : currentRemainingPercent;
    const storedValueSuffix = currentRemainingPercent === null
      ? nullableString(model.valueSuffix)
      : "%";

    statements.push(
      env.DB.prepare(
        `INSERT INTO quota_samples (
          id,
          device_id,
          provider,
          account_name,
          model_id,
          model_name,
          current_interval_total,
          current_interval_remaining,
          weekly_total,
          weekly_remaining,
          reset_start_time,
          reset_end_time,
          weekly_start_time,
          weekly_end_time,
          value_suffix,
          detail_text,
          sampled_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          device_id = excluded.device_id,
          provider = excluded.provider,
          account_name = excluded.account_name,
          model_id = excluded.model_id,
          model_name = excluded.model_name,
          current_interval_total = excluded.current_interval_total,
          current_interval_remaining = excluded.current_interval_remaining,
          weekly_total = excluded.weekly_total,
          weekly_remaining = excluded.weekly_remaining,
          reset_start_time = excluded.reset_start_time,
          reset_end_time = excluded.reset_end_time,
          weekly_start_time = excluded.weekly_start_time,
          weekly_end_time = excluded.weekly_end_time,
          value_suffix = excluded.value_suffix,
          detail_text = excluded.detail_text,
          sampled_at = excluded.sampled_at
        WHERE (device_id, provider, account_name, model_id, model_name,
               current_interval_total, current_interval_remaining, weekly_total, weekly_remaining,
               reset_start_time, reset_end_time, weekly_start_time, weekly_end_time,
               value_suffix, detail_text, sampled_at)
          IS NOT (excluded.device_id, excluded.provider, excluded.account_name, excluded.model_id, excluded.model_name,
                  excluded.current_interval_total, excluded.current_interval_remaining, excluded.weekly_total, excluded.weekly_remaining,
                  excluded.reset_start_time, excluded.reset_end_time, excluded.weekly_start_time, excluded.weekly_end_time,
                  excluded.value_suffix, excluded.detail_text, excluded.sampled_at)`
      ).bind(
        stableSampleID(deviceID, provider, modelID, sampledAt),
        deviceID,
        provider,
        nullableString(model.accountName),
        modelID,
        modelName,
        storedCurrentTotal,
        storedCurrentRemaining,
        integerValue(model.weeklyTotal),
        integerValue(model.weeklyRemaining),
        nullableString(model.resetStartTime),
        nullableString(model.resetEndTime),
        nullableString(model.weeklyStartTime),
        nullableString(model.weeklyEndTime),
        storedValueSuffix,
        nullableString(model.detailText),
        sampledAt
      )
    );
  }

  await env.DB.batch(statements);
  const cleanupResult = await cleanupExpiredQuotaSamples(env, sampledAt, retentionDays);
  return json({
    ok: true,
    inserted: statements.length - 1,
    retention_days: retentionDays,
    deleted_expired_quota_samples: changesCount(cleanupResult),
  });
}

async function listQuotaSamples(url, env) {
  const deviceID = url.searchParams.get("device_id");
  const limit = Math.min(Math.max(Number(url.searchParams.get("limit") || 100), 1), 500);
  const includeHistory = url.searchParams.get("history") === "1";

  if (includeHistory) {
    if (deviceID) {
      const result = await env.DB.prepare(
        `SELECT quota_samples.*
         FROM quota_samples
         WHERE device_id = ?
         ORDER BY sampled_at DESC
         LIMIT ?`
      ).bind(deviceID, limit).all();

      return json({ ok: true, samples: result.results || [] });
    }

    // Existing device/time indexes make this bounded by devices × limit, rather
    // than sorting the entire retention history. A device's (limit + 1)th row
    // cannot appear in the global top limit. Equal timestamps had no defined
    // ordering in the original SQL and still have no API ordering guarantee.
    const devices = await env.DB.prepare(`SELECT id FROM devices`).all();
    let samples = [];
    for (const device of devices.results || []) {
      const result = await env.DB.prepare(
        `SELECT quota_samples.* FROM quota_samples
         WHERE device_id = ? ORDER BY sampled_at DESC LIMIT ?`
      ).bind(device.id, limit).all();
      samples = samples.concat(result.results || []);
      samples.sort((a, b) => a.sampled_at < b.sampled_at ? 1 : a.sampled_at > b.sampled_at ? -1 : 0);
      samples.length = Math.min(samples.length, limit);
    }
    return json({ ok: true, samples });
  }

  // Enabled only after the additive migration has backfilled and verified the
  // compact latest-pointer table. Old deployments retain their existing path.
  // CROSS JOIN fixes the history lookup after the small heads relation: without
  // it SQLite can reorder the joins into a full historical-table scan.
  if (env.LATEST_INDEX_ENABLED === "true") {
    const sourceFilter = deviceID ? "WHERE device_id = ?" : "";
    const joinDevice = deviceID ? "AND latest.device_id = heads.device_id" : "";
    const deviceGroup = deviceID ? "device_id," : "";
    const query = env.DB.prepare(
      `SELECT quota_samples.* FROM quota_sample_heads AS heads
       INNER JOIN (
         SELECT ${deviceGroup} provider, account_key, model_id, MAX(sampled_at) AS sampled_at
         FROM quota_sample_heads ${sourceFilter}
         GROUP BY ${deviceGroup} provider, account_key, model_id
       ) latest ON latest.provider = heads.provider
         AND latest.account_key = heads.account_key
         AND latest.model_id = heads.model_id
         AND latest.sampled_at = heads.sampled_at ${joinDevice}
       CROSS JOIN quota_samples ON quota_samples.id = heads.sample_id
       ORDER BY quota_samples.sampled_at DESC LIMIT ?`
    );
    const result = await (deviceID ? query.bind(deviceID, limit) : query.bind(limit)).all();
    return json({ ok: true, samples: result.results || [] });
  }

  if (!deviceID) {
    const result = await env.DB.prepare(
      `SELECT quota_samples.*
       FROM quota_samples
       INNER JOIN (
         SELECT provider, COALESCE(account_name, '') AS account_key, model_id, MAX(sampled_at) AS sampled_at
         FROM quota_samples
         GROUP BY provider, COALESCE(account_name, ''), model_id
       ) latest
         ON latest.provider = quota_samples.provider
        AND latest.account_key = COALESCE(quota_samples.account_name, '')
        AND latest.model_id = quota_samples.model_id
        AND latest.sampled_at = quota_samples.sampled_at
       ORDER BY quota_samples.sampled_at DESC
       LIMIT ?`
    ).bind(limit).all();

    return json({ ok: true, samples: result.results || [] });
  }

  const result = await env.DB.prepare(
    `SELECT quota_samples.*
     FROM quota_samples
     INNER JOIN (
       SELECT device_id, provider, COALESCE(account_name, '') AS account_key, model_id, MAX(sampled_at) AS sampled_at
       FROM quota_samples
       WHERE device_id = ?
       GROUP BY device_id, provider, COALESCE(account_name, ''), model_id
     ) latest
       ON latest.device_id = quota_samples.device_id
      AND latest.provider = quota_samples.provider
      AND latest.account_key = COALESCE(quota_samples.account_name, '')
      AND latest.model_id = quota_samples.model_id
      AND latest.sampled_at = quota_samples.sampled_at
     ORDER BY quota_samples.sampled_at DESC
     LIMIT ?`
  ).bind(deviceID, limit).all();

  return json({ ok: true, samples: result.results || [] });
}

async function listDevices(url, env) {
  const deviceID = url.searchParams.get("device_id");
  if (deviceID) {
    const result = await env.DB.prepare(
      `SELECT id, name, created_at, last_seen_at
       FROM devices
       WHERE id = ?
       ORDER BY last_seen_at DESC`
    ).bind(deviceID).all();

    return json({ ok: true, devices: result.results || [] });
  }

  const result = await env.DB.prepare(
    `SELECT id, name, created_at, last_seen_at
     FROM devices
     ORDER BY last_seen_at DESC`
  ).all();

  return json({ ok: true, devices: result.results || [] });
}

async function listAccountSummaries(url, env) {
  const limit = Math.min(Math.max(Number(url.searchParams.get("limit") || 200), 1), 1000);
  const result = await env.DB.prepare(
    `SELECT
       provider,
       COALESCE(account_name, '') AS account_name,
       COUNT(*) AS sample_count,
       COUNT(DISTINCT COALESCE(model_id, model_name)) AS model_count,
       MIN(sampled_at) AS earliest_sampled_at,
       MAX(sampled_at) AS latest_sampled_at
     FROM quota_samples
     GROUP BY provider, COALESCE(account_name, '')
     ORDER BY latest_sampled_at DESC
     LIMIT ?`
  ).bind(limit).all();

  return json({ ok: true, accounts: result.results || [] });
}

async function deleteDeviceData(url, env) {
  const provider = stringValue(url.searchParams.get("provider"));
  const accountName = stringValue(url.searchParams.get("account_name"));
  if (provider) {
    return await deleteAccountData(provider, accountName, env);
  }

  const deviceID = stringValue(url.searchParams.get("device_id"));
  if (!deviceID) {
    return json({ error: "missing_device_id" }, 400);
  }

  const quotaResult = await deleteQuotaGroup(env,
    `DELETE FROM quota_sample_heads WHERE device_id = ?`,
    `DELETE FROM quota_samples WHERE device_id = ?`, [deviceID]);
  const settingsResult = await env.DB.prepare(
    `DELETE FROM settings WHERE device_id = ?`
  ).bind(deviceID).run();
  const devicesResult = await env.DB.prepare(
    `DELETE FROM devices WHERE id = ?`
  ).bind(deviceID).run();

  return json({
    ok: true,
    deleted_quota_samples: changesCount(quotaResult),
    deleted_settings: changesCount(settingsResult),
    deleted_devices: changesCount(devicesResult),
  });
}

async function deleteAccountData(provider, accountName, env) {
  // Preserve the pre-existing cross-provider account-name deletion semantics.
  const quotaResult = accountName
    ? await deleteQuotaGroup(env,
      `DELETE FROM quota_sample_heads WHERE account_key = ?`,
      `DELETE FROM quota_samples WHERE account_name = ?`, [accountName])
    : await deleteQuotaGroup(env,
      `DELETE FROM quota_sample_heads WHERE provider = ? AND account_key = ''`,
      `DELETE FROM quota_samples WHERE provider = ? AND (account_name IS NULL OR account_name = '')`, [provider]);

  return json({
    ok: true,
    deleted_quota_samples: changesCount(quotaResult),
    deleted_settings: 0,
    deleted_devices: 0,
  });
}

async function cleanupExpiredQuotaSamples(env, sampledAt, retentionDays) {
  const baseTime = Date.parse(sampledAt);
  const now = Number.isFinite(baseTime) ? baseTime : Date.now();
  const cutoff = new Date(now - retentionDays * 24 * 60 * 60 * 1000).toISOString();
  const devices = await env.DB.prepare(`SELECT id FROM devices`).all();
  let changes = 0;
  for (const device of devices.results || []) {
    const result = await deleteQuotaGroup(env,
      `DELETE FROM quota_sample_heads WHERE device_id = ? AND sampled_at < ?`,
      `DELETE FROM quota_samples WHERE device_id = ? AND sampled_at < ?`,
      [device.id, cutoff]);
    changes += changesCount(result);
  }
  return { meta: { changes } };
}

async function deleteQuotaGroup(env, headsSQL, samplesSQL, values) {
  const samples = env.DB.prepare(samplesSQL).bind(...values);
  // Remove complete-group / fully expired heads first, in the same transaction.
  // Otherwise a per-row DELETE trigger could repeatedly restore an older head
  // while a bulk deletion is working through the same group's history.
  try {
    const results = await env.DB.batch([
      env.DB.prepare(headsSQL).bind(...values), samples,
    ]);
    return results[1];
  } catch (error) {
    // Before the additive migration, keep the existing schema operational.
    // Once the table exists, maintain it even while latest reads are disabled:
    // this also makes the migration/deployment window and flag rollback safe.
    if (env.LATEST_INDEX_ENABLED !== "true" && /no such table: (?:main\.)?quota_sample_heads/i.test(error.message)) {
      return await samples.run();
    }
    throw error;
  }
}

function json(body, status = 200) {
  return cors(new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  }));
}

function cors(response) {
  response.headers.set("access-control-allow-origin", "*");
  response.headers.set("access-control-allow-methods", "GET,POST,DELETE,OPTIONS");
  response.headers.set("access-control-allow-headers", "authorization,content-type");
  return response;
}

function stableSampleID(deviceID, provider, modelID, sampledAt) {
  return `${deviceID}:${provider}:${modelID}:${sampledAt}`;
}

function stringValue(value) {
  return String(value || "").trim();
}

function nullableString(value) {
  const next = stringValue(value);
  return next.length > 0 ? next : null;
}

function integerValue(value) {
  const next = Number(value);
  return Number.isFinite(next) ? Math.trunc(next) : 0;
}

function nullableInteger(value) {
  const next = Number(value);
  return Number.isFinite(next) ? Math.trunc(next) : null;
}

function retentionDaysValue(value) {
  const next = Number(value);
  if (!Number.isFinite(next)) {
    return 30;
  }
  return Math.min(Math.max(Math.trunc(next), 1), 180);
}

function changesCount(result) {
  return Number(result?.meta?.changes || 0);
}
