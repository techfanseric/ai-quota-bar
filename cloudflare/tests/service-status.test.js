import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/worker.js';
import { readFile } from 'node:fs/promises';
const assets = { fetch: async () => new Response(await readFile(new URL('../public/index.html', import.meta.url)), {headers:{'content-type':'text/html; charset=utf-8'}}) };

test('public product page needs neither credentials nor database', async () => {
  const response = await worker.fetch(new Request('https://example.com/'), {ASSETS: assets});
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type'), /text\/html/);
  assert.match(await response.text(), /AI Quota Bar/);
});
test('public liveness works, usage and legacy data still require authentication', async () => {
  const health = await worker.fetch(new Request('https://example.com/healthz'), {});
  assert.deepEqual(await health.json(), { ok: true, service: 'ai-quota-bar-sync' });
  for (const path of ['/v1/usage/summary', '/v1/quota-samples']) {
    const response = await worker.fetch(new Request('https://example.com' + path), { SYNC_TOKEN: 'secret' });
    assert.equal(response.status, 401);
  }
});

test('migration freeze rejects writes for durable client retry while keeping health readable', async () => {
  const env = { MIGRATION_READ_ONLY: 'true' };
  const response = await worker.fetch(new Request('https://example.com/v1/usage/events/batch', {method:'POST'}), env);
  assert.equal(response.status, 503);
  assert.equal(response.headers.get('retry-after'), '60');
  assert.equal((await worker.fetch(new Request('https://example.com/healthz'), env)).status, 200);
});

 test('landing assets do not weaken API authentication and support HEAD', async () => {
  for (const path of ['/site.css', '/demo.js', '/favicon.svg', '/robots.txt', '/sitemap.xml']) {
    const result = await worker.fetch(new Request('https://example.com'+path, {method:'HEAD'}), {ASSETS:assets});
    assert.equal(result.status,200);
    assert.match(result.headers.get('content-security-policy'), /connect-src 'none'/);
  }
  const result=await worker.fetch(new Request('https://example.com/private.sql'), {ASSETS:assets});
  assert.equal(result.status,404);
});

test('embedded real dashboard preview is public but cannot connect to live APIs', async () => {
  for (const path of ['/mobile-preview', '/mobile-preview.css', '/mobile-preview.js']) {
    const result = await worker.fetch(new Request('https://example.com' + path), {ASSETS:assets});
    assert.equal(result.status, 200);
    const policy = result.headers.get('content-security-policy');
    assert.match(policy, /connect-src 'none'/);
    assert.match(policy, /frame-ancestors 'self'/);
    assert.match(policy, /form-action 'none'/);
  }
  const privateResult = await worker.fetch(new Request('https://example.com/v1/admin/overview'), {});
  assert.equal(privateResult.status, 401);
});

test('changelog is public read-only content with no API connections', async () => {
  for (const path of ['/changelog', '/changelog/', '/changelog.html', '/changelog.css', '/changelog.js', '/app-icon.png', '/cycle-demo.js']) {
    const result = await worker.fetch(new Request('https://example.com' + path), {ASSETS: assets});
    assert.equal(result.status, 200);
    assert.match(result.headers.get('content-security-policy'), /connect-src 'none'/);
    const post = await worker.fetch(new Request('https://example.com' + path, {method:'POST'}), {ASSETS:assets});
    assert.equal(post.status, 404);
  }
});

 test('app update normalizes the release version and survives GitHub failure', async (t) => {
  const mocked=t.mock.method(globalThis,'fetch',async()=>new Response(JSON.stringify({tag_name:' v1.19.0 ',html_url:'https://github.com/release',assets:[{name:'AIQuotaBar.dmg',browser_download_url:'https://github.com/download'}]})));
  const request=new Request('https://example.com/v1/app-update');
  const response=await worker.fetch(request,{});
  assert.equal(response.status,200);
  const data=await response.json();
  assert.equal(data.version,'1.19.0');
  assert.equal(data.source,'github-proxy');
  assert.equal(data.download_url,'https://github.com/download');
  mocked.mock.mockImplementation(async()=>{throw new Error('unavailable')});
  const fallback=await worker.fetch(request,{});
  assert.equal(fallback.status,200);
  const cached=await fallback.json();
  assert.equal(cached.version,'1.19.0');
  assert.equal(cached.source,'worker-fallback');
 });
