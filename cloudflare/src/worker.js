import { listQuotaSamples, listAccountSummaries, listDevices } from './legacy-quota.js';
import { teamQuota, quotaAccounts, deleteTeamQuota } from './team-quota.js';
import { operations, authorized } from "./operations.js";
import { localUsage, identity } from "./local-usage.js";
import { teamService } from "./team.js";
import { feedbackService } from "./feedback.js";

export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url);
      if (env.MIGRATION_READ_ONLY === "true" && ["POST", "PUT", "DELETE"].includes(request.method)) {
        return new Response(JSON.stringify({error:"migration_in_progress"}), {status:503, headers:{"content-type":"application/json", "retry-after":"60"}});
      }

      if (url.pathname.startsWith('/v1/admin/data/') || url.pathname === '/v1/admin/d1-usage') {
        if (!await authorized(request, env)) return json({error:'unauthorized'},401);
        if (request.headers.get('origin') && request.headers.get('origin') !== url.origin) return json({error:'invalid_origin'},403);
        if (url.pathname === '/v1/admin/d1-usage' && request.method === 'GET') return await d1Usage(env);
        if (url.pathname === '/v1/admin/data/teams' && request.method === 'GET') {
          const result = await env.DB.prepare(`SELECT known.team_id,COALESCE(t.team_name,known.team_id) team_name,t.created_at,
            (SELECT COUNT(*) FROM usage_members m WHERE m.team_id=known.team_id) members,
            (SELECT COUNT(*) FROM usage_devices d WHERE d.team_id=known.team_id AND revoked=0) devices,
            (SELECT COUNT(*) FROM usage_events e WHERE e.team_id=known.team_id) events
            FROM (SELECT team_id FROM usage_teams UNION SELECT team_id FROM usage_devices) known
            LEFT JOIN usage_teams t ON t.team_id=known.team_id ORDER BY t.created_at DESC LIMIT 1000`).all();
          return json({ok:true,teams:result.results});
        }
        const teamID=url.searchParams.get('team_id');
        if (url.pathname === '/v1/admin/data/accounts' && request.method === 'GET') {
          if (!teamID) return json({error:'missing_team'},400);
          return json({ok:true,accounts:await quotaAccounts(env,teamID)});
        }
        if (url.pathname === '/v1/admin/data/accounts' && request.method === 'DELETE') {
          if (!teamID) return json({error:'missing_team'},400);
          return await deleteTeamQuota(env,teamID,'platform-admin',url.searchParams.get('provider'),url.searchParams.get('account_name'));
        }
        if (url.pathname === '/v1/admin/data/audit' && request.method === 'GET') {
          const rows=await env.DB.prepare('SELECT * FROM team_data_audit ORDER BY created_at DESC LIMIT 100').all();
          return json({ok:true,items:rows.results});
        }
        if (url.pathname === '/v1/admin/data/legacy/accounts' && request.method === 'GET') return await listAccountSummaries(url,env);
        if (url.pathname === '/v1/admin/data/legacy/samples' && request.method === 'GET') return await listQuotaSamples(url,env);
        if (url.pathname === '/v1/admin/data/legacy/devices' && request.method === 'GET') return await listDevices(url,env);
        // Historical global data is read-only until its ownership is explicitly resolved.
        return json({error:'not_found'},404);
      }
      if (url.pathname.startsWith("/v1/admin/") || url.pathname.startsWith("/v1/telemetry/")) {
        return await operations(request, env, url);
      }
      if (url.pathname.startsWith("/v1/team/")) {
        return await teamService(request, env, url);
      }
      if (url.pathname.startsWith("/v1/feedback")) {
        return await feedbackService(request, env, url);
      }
      if (["GET", "HEAD"].includes(request.method) && ["/team", "/team/", "/team.css", "/team.js"].includes(url.pathname)) {
        const assetURL = new URL(request.url);
        if (["/team", "/team/"].includes(url.pathname)) assetURL.pathname = "/team";
        const asset = await env.ASSETS.fetch(new Request(assetURL, request));
        const response = new Response(asset.body, asset);
        response.headers.set("cache-control", "no-store");
        response.headers.set("x-robots-tag", "noindex, nofollow");
        response.headers.set("content-security-policy", "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'");
        response.headers.set("x-content-type-options", "nosniff");
        response.headers.set("referrer-policy", "no-referrer");
        return response;
      }
      // The public feedback wall. Unlike /team it is indexable content, so no
      // x-robots-tag is set; it still needs connect-src 'self' for its API calls.
      if (["GET", "HEAD"].includes(request.method) && ["/feedback", "/feedback/", "/feedback.css", "/feedback.js"].includes(url.pathname)) {
        const assetURL = new URL(request.url);
        if (["/feedback", "/feedback/"].includes(url.pathname)) assetURL.pathname = "/feedback";
        const asset = await env.ASSETS.fetch(new Request(assetURL, request));
        const response = new Response(asset.body, asset);
        response.headers.set("cache-control", "no-store");
        response.headers.set("content-security-policy", "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'");
        response.headers.set("x-content-type-options", "nosniff");
        response.headers.set("referrer-policy", "no-referrer");
        return response;
      }
      if (["GET", "HEAD"].includes(request.method) && ["/admin", "/admin/", "/admin.css", "/admin.js"].includes(url.pathname)) {
        const assetURL = new URL(request.url);
        if (["/admin", "/admin/"].includes(url.pathname)) assetURL.pathname = "/admin";
        const asset = await env.ASSETS.fetch(new Request(assetURL, request));
        const response = new Response(asset.body, asset);
        response.headers.set("cache-control", "no-store");
        response.headers.set("x-robots-tag", "noindex, nofollow");
        response.headers.set("content-security-policy", "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'");
        response.headers.set("x-content-type-options", "nosniff");
        response.headers.set("referrer-policy", "no-referrer");
        return response;
      }
      // Only these public assets bypass API authentication. No usage data is
      // embedded in the product site or requested by its interactive demos.
      if (["GET", "HEAD"].includes(request.method) && ["/mobile-preview", "/mobile-preview.css", "/mobile-preview.js"].includes(url.pathname)) {
        const asset = await env.ASSETS.fetch(request);
        const response = new Response(asset.body, asset);
        response.headers.set("content-security-policy", "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self'; connect-src 'none'; media-src 'none'; frame-ancestors 'self'; base-uri 'none'; form-action 'none'");
        response.headers.set("x-content-type-options", "nosniff");
        response.headers.set("x-robots-tag", "noindex");
        response.headers.set("cache-control", "public, max-age=0, must-revalidate");
        return response;
      }
      const publicPaths = new Set(["/", "/index.html", "/site.css", "/demo.js", "/favicon.svg", "/robots.txt", "/sitemap.xml", "/changelog", "/changelog/", "/changelog.html", "/changelog.css", "/changelog.js", "/app-icon.png", "/cycle-demo.js"]);
      if (["GET", "HEAD"].includes(request.method) && publicPaths.has(url.pathname)) {
        const asset = await env.ASSETS.fetch(request);
        const response = new Response(asset.body, asset);
        response.headers.set("content-security-policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'");
        response.headers.set("x-content-type-options", "nosniff");
        response.headers.set("referrer-policy", "strict-origin-when-cross-origin");
        response.headers.set("cache-control", "public, max-age=0, must-revalidate");
        return response;
      }
      if (request.method === "GET" && url.pathname === "/healthz") {
        return json({ ok: true, service: "ai-quota-bar-sync" });
      }

      if (request.method === "OPTIONS") {
        return cors(new Response(null, { status: 204 }));
      }

      if (request.method === "GET" && url.pathname === "/v1/app-update") {
        return await appUpdateManifest(env);
      }

      if (url.pathname.startsWith("/v1/usage/")) {
        return await localUsage(request, env, url);
      }

      if (['/v1/quota-samples','/v1/account-summaries','/v1/devices','/v1/data','/v1/health'].includes(url.pathname)) {
        const who = await identity(request,env);
        if (!who) return json({error:'team_connection_required'},401);
        if (url.pathname === '/v1/health' && request.method === 'GET') return json({ok:true});
        return await teamQuota(request,env,url,who);
      }
      if (url.pathname === '/v1/d1-usage') return json({error:'platform_admin_required'},403);

      return json({ error: "not_found" }, 404);
    } catch (error) {
      const d1Response = d1ErrorResponse(error);
      if (d1Response) return d1Response;
      return json({ error: "internal_error", message: error.message }, 500);
    }
  },
};

/// D1 故障分类：客户端靠 `error` code 区分"当日配额耗尽"（等 UTC 0 点重置即可）
/// 和其它 D1 错误，不再统一显示 internal_error。
/// code 与客户端 `CloudSyncService.isNonRetryable` 的判定保持同语义。
function d1ErrorResponse(error) {
  const message = String((error && error.message) || error || "");
  const normalized = message.toLowerCase();
  if (!normalized.includes("d1")) return null;

  const isDailyLimit =
    normalized.includes("daily_limit") ||
    normalized.includes("daily_read_limit") ||
    normalized.includes("daily_write_limit") ||
    ((normalized.includes("daily") || normalized.includes("per day")) &&
      normalized.includes("exceeded") &&
      (normalized.includes("row read") || normalized.includes("rows read") ||
        normalized.includes("row write") || normalized.includes("rows written")));
  if (isDailyLimit) {
    return json({
      error: "d1_daily_limit_exceeded",
      message,
      hint: "D1 free plan daily rows quota exhausted; resets at 00:00 UTC.",
    }, 503);
  }
  return json({ error: "d1_error", message }, 503);
}

// D1 free plan 单日 rowsRead 上限（账号级）。Workers Paid 后此限制消失。
const FREE_PLAN_DAILY_READ_LIMIT = 5_000_000;
const D1_USAGE_CACHE_TTL_MS = 5 * 60 * 1000;

/// GET /v1/d1-usage — 参考 TunnelWatchPage /api/usage：
/// 走 Cloudflare GraphQL Analytics API（查 metrics 不消耗 D1 read 配额），
/// 返回账号级 + 本库当日 rowsRead/rowsWritten 与配额余量，供客户端做状态反馈。
/// 未配置 CF_API_TOKEN 时返回 503 + code=missing_token + 配置指引。
async function d1Usage(env) {
  if (!env.CF_API_TOKEN) {
    return json({
      ok: false,
      code: "missing_token",
      error: "CF_API_TOKEN secret 未配置 — 无法拉取 D1 用量",
      help: "去 https://dash.cloudflare.com/profile/api-tokens 创建 token（Account Analytics: Read，只读 scope），然后 `wrangler secret put CF_API_TOKEN` 并重新部署。",
    }, 503);
  }
  if (!env.CF_ACCOUNT_ID || !env.D1_DATABASE_ID) {
    return json({
      ok: false,
      code: "missing_config",
      error: "wrangler.toml [vars] 缺 CF_ACCOUNT_ID 或 D1_DATABASE_ID",
    }, 503);
  }

  const now = new Date();
  const startDate = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  const endDate = new Date(startDate.getTime() + 24 * 60 * 60 * 1000);
  const fmt = (d) => d.toISOString().slice(0, 10);

  // 5 分钟边缘缓存：防 GraphQL rate limit，客户端轮询也不打爆配额统计接口
  const cacheKey = `https://d1-usage.internal/${env.D1_DATABASE_ID}/${fmt(startDate)}`;
  const cache = globalThis.caches && globalThis.caches.default;
  if (cache) {
    const cached = await cache.match(cacheKey);
    if (cached) return cached;
  }

  const query = `
    query D1Usage($accountTag: String!, $databaseId: String!, $start: Date!, $end: Date!) {
      viewer {
        accounts(filter: { accountTag: $accountTag }) {
          accountUsage: d1AnalyticsAdaptiveGroups(
            limit: 1
            filter: { date_geq: $start, date_leq: $end }
          ) { sum { rowsRead rowsWritten } }
          databaseUsage: d1AnalyticsAdaptiveGroups(
            limit: 1
            filter: { date_geq: $start, date_leq: $end, databaseId: $databaseId }
          ) { sum { rowsRead rowsWritten } }
        }
      }
    }
  `;
  const variables = {
    accountTag: env.CF_ACCOUNT_ID,
    databaseId: env.D1_DATABASE_ID,
    // date_leq 是闭区间，起止都用今天；不要把明天纳入统计
    start: fmt(startDate),
    end: fmt(startDate),
  };

  let resp;
  try {
    resp = await fetch("https://api.cloudflare.com/client/v4/graphql", {
      method: "POST",
      headers: {
        authorization: `Bearer ${env.CF_API_TOKEN}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ query, variables }),
    });
  } catch (error) {
    return json({ ok: false, code: "graphql_fetch_failed", error: `GraphQL fetch failed: ${error.message}` }, 502);
  }
  if (!resp.ok) {
    const text = await resp.text().catch(() => "");
    return json({ ok: false, code: `graphql_http_${resp.status}`, error: `GraphQL ${resp.status}: ${text.slice(0, 200)}` }, 502);
  }
  const body = await resp.json();
  if (body.errors && body.errors.length) {
    return json({ ok: false, code: "graphql_error", error: `GraphQL error: ${body.errors.map((e) => e.message).join("; ")}` }, 502);
  }
  const account = body.data && body.data.viewer && body.data.viewer.accounts && body.data.viewer.accounts[0];
  if (!account || !Array.isArray(account.accountUsage) || !Array.isArray(account.databaseUsage)) {
    return json({ ok: false, code: "graphql_missing_data", error: "Cloudflare 未返回账号用量，无法确认余量" }, 502);
  }

  const sum = (account.accountUsage[0] && account.accountUsage[0].sum) || { rowsRead: 0, rowsWritten: 0 };
  const databaseSum = (account.databaseUsage[0] && account.databaseUsage[0].sum) || { rowsRead: 0, rowsWritten: 0 };
  const rowsRead = sum.rowsRead || 0;

  const response = json({
    ok: true,
    rowsRead,
    rowsWritten: sum.rowsWritten || 0,
    scope: "account",
    databaseRowsRead: databaseSum.rowsRead || 0,
    databaseRowsWritten: databaseSum.rowsWritten || 0,
    remaining: Math.max(0, FREE_PLAN_DAILY_READ_LIMIT - rowsRead),
    limit: FREE_PLAN_DAILY_READ_LIMIT,
    pct: Math.min(100, (rowsRead / FREE_PLAN_DAILY_READ_LIMIT) * 100),
    observedAt: now.toISOString(),
    windowStart: startDate.toISOString(),
    resetsAt: endDate.toISOString(),
  });

  if (cache) {
    const ttlSeconds = Math.max(1, Math.min(D1_USAGE_CACHE_TTL_MS / 1000, Math.floor((endDate.getTime() - now.getTime()) / 1000)));
    response.headers.set("cache-control", `public, max-age=${ttlSeconds}`);
    await cache.put(cacheKey, response.clone());
  }
  return response;
}

async function appUpdateManifest(env) {
  const fallbackVersion = env.APP_LATEST_VERSION || "1.17.1";
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

function json(body, status = 200) {
  return cors(new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  }));
}

function cors(response) {
  response.headers.set("access-control-allow-origin", "*");
  response.headers.set("access-control-allow-methods", "GET,POST,DELETE,OPTIONS");
  response.headers.set("access-control-allow-headers", "authorization,content-type");
  return response;
}
