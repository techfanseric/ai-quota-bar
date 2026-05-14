export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url);

      if (request.method === "OPTIONS") {
        return cors(new Response(null, { status: 204 }));
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

      if (request.method === "GET" && url.pathname === "/v1/devices") {
        return await listDevices(env);
      }

      return json({ error: "not_found" }, 404);
    } catch (error) {
      return json({ error: "internal_error", message: error.message }, 500);
    }
  },
};

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

  if (!deviceID || !sampledAt || models.length === 0) {
    return json({ error: "invalid_payload" }, 400);
  }

  const statements = [
    env.DB.prepare(
      `INSERT INTO devices (id, last_seen_at)
       VALUES (?, ?)
       ON CONFLICT(id) DO UPDATE SET last_seen_at = excluded.last_seen_at`
    ).bind(deviceID, sampledAt),
  ];

  for (const model of models) {
    const provider = stringValue(model.provider);
    const modelID = stringValue(model.modelID);
    const modelName = stringValue(model.modelName);

    if (!provider || !modelID || !modelName) {
      continue;
    }

    statements.push(
      env.DB.prepare(
        `INSERT OR REPLACE INTO quota_samples (
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
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
      ).bind(
        stableSampleID(deviceID, provider, modelID, sampledAt),
        deviceID,
        provider,
        nullableString(model.accountName),
        modelID,
        modelName,
        integerValue(model.currentIntervalTotal),
        integerValue(model.currentIntervalRemaining),
        integerValue(model.weeklyTotal),
        integerValue(model.weeklyRemaining),
        nullableString(model.resetStartTime),
        nullableString(model.resetEndTime),
        nullableString(model.weeklyStartTime),
        nullableString(model.weeklyEndTime),
        nullableString(model.valueSuffix),
        nullableString(model.detailText),
        sampledAt
      )
    );
  }

  await env.DB.batch(statements);
  return json({ ok: true, inserted: statements.length - 1 });
}

async function listQuotaSamples(url, env) {
  const deviceID = url.searchParams.get("device_id");
  const limit = Math.min(Math.max(Number(url.searchParams.get("limit") || 100), 1), 500);

  if (!deviceID) {
    const result = await env.DB.prepare(
      `SELECT *
       FROM quota_samples
       ORDER BY sampled_at DESC
       LIMIT ?`
    ).bind(limit).all();

    return json({ ok: true, samples: result.results || [] });
  }

  const result = await env.DB.prepare(
    `SELECT *
     FROM quota_samples
     WHERE device_id = ?
     ORDER BY sampled_at DESC
     LIMIT ?`
  ).bind(deviceID, limit).all();

  return json({ ok: true, samples: result.results || [] });
}

async function listDevices(env) {
  const result = await env.DB.prepare(
    `SELECT id, name, created_at, last_seen_at
     FROM devices
     ORDER BY last_seen_at DESC`
  ).all();

  return json({ ok: true, devices: result.results || [] });
}

function json(body, status = 200) {
  return cors(new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  }));
}

function cors(response) {
  response.headers.set("access-control-allow-origin", "*");
  response.headers.set("access-control-allow-methods", "GET,POST,OPTIONS");
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
