import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { prepareReleaseHistory } from '../scripts/sync-releases.mjs';
import { buildChangelog } from '../scripts/build-changelog.mjs';
import { checkReleaseSite } from '../scripts/check-release-site.mjs';
import worker from '../src/worker.js';

const repository = 'https://github.com/techfanseric/ai-quota-bar';
const stable = '1.39.0';
const windows = '1.38.6-beta.1';
const release = (tag, date, extra = {}) => ({
  tag_name: `v${tag}`, name: tag, published_at: date,
  html_url: `${repository}/releases/tag/v${tag}`, body: 'Release notes',
  prerelease: false, draft: false, assets: [{name: 'AIQuotaBar.pkg'}], ...extra,
});
const stableRelease = release(stable, '2026-10-28T03:00:00Z');
const windowsRelease = release(windows, '2026-10-28T04:00:00Z', {
  prerelease: true, assets: [{name: 'AIQuotaBar-win-x64.zip'}],
});

test('release sync keeps published betas, excludes drafts, sorts pages and preserves translations', () => {
  const result = prepareReleaseHistory([
    [stableRelease, release('9.0.0', '2026-10-29T00:00:00Z', {draft: true})],
    [windowsRelease, release('1.38.5', '2026-10-27T00:00:00Z')],
  ], [{tag_name: stableRelease.tag_name, name_en: 'Translated title', body_zh: '中文记录'}]);
  assert.deepEqual(result.map(r => r.tag_name), [`v${windows}`, `v${stable}`, 'v1.38.5']);
  assert.equal(result[0].platform, 'windows');
  assert.equal(result[1].platform, 'macos');
  assert.equal(result[1].name_en, 'Translated title');
  assert.equal(result[1].body_zh, '中文记录');
  assert.equal(result[0].body, windowsRelease.body);
});

test('release sync refuses an empty or beta-only published history', () => {
  for (const feed of [[], [[windowsRelease]], [[{...stableRelease, draft: true}]]]) {
    assert.throws(() => prepareReleaseHistory(feed), /No published stable releases/);
  }
});

test('both changelogs reserve latest for stable when a newer beta is first and safely render Markdown', async t => {
  const outputDir = await mkdtemp(join(tmpdir(), 'aqb-changelog-'));
  t.after(() => rm(outputDir, {recursive: true, force: true}));
  await mkdir(join(outputDir, 'en'));
  const releasesPath = join(outputDir, 'releases.json');
  const body = '<script>alert("raw")</script>\n\n'
    + '[unsafe](javascript:alert%281%29)\n\n'
    + '![tracking](https://evil.example/pixel.png)\n\n'
    + '[safe](https://example.com/notes?x=1&y=2)';
  await writeFile(releasesPath, JSON.stringify(prepareReleaseHistory([[windowsRelease, {...stableRelease, body}]])));
  await buildChangelog({releasesPath, outputDir});
  for (const dir of ['', 'en/']) {
    const html = await readFile(join(outputDir, dir, 'changelog.html'), 'utf8');
    const articles = [...html.matchAll(/<article\b[^>]*id="([^"]+)"[^>]*>([\s\S]*?)<\/article>/g)];
    assert.deepEqual(articles.map(a => a[1]), [`v${windows}`, `v${stable}`]);
    assert.match(articles[0][2], /Windows (?:公测版|beta)/);
    assert.doesNotMatch(articles[0][2], /最新 macOS 正式版|Latest macOS stable/);
    assert.match(articles[1][2], /最新 macOS 正式版|Latest macOS stable/);
    assert.equal((html.match(/<span class="latest">(?:最新 macOS 正式版|Latest macOS stable)<\/span>/g) || []).length, 1);
    assert.match(articles[1][2], /&lt;script&gt;/);
    assert.doesNotMatch(articles[1][2], /<script|<img|href="javascript:|src="https:\/\/evil/i);
    assert.match(articles[1][2], /href="https:\/\/example.com\/notes\?x=1&amp;y=2" rel="noopener noreferrer"/);
    assert.match(html, /2 (?:releases)|共 2 个发布版本/);
  }
});

function siteFiles() {
  const homepage = `<p>v${stable}</p><a href="${repository}/releases/latest/download/AIQuotaBar.pkg">macOS</a>`
    + `<a href="${repository}/releases/download/v${windows}/AIQuotaBar-win-x64.zip">Windows</a>`;
  const changelog = `<article id="v${windows}"><span class="latest">Windows beta</span></article>`
    + `<article id="v${stable}"><span class="latest">Latest macOS stable</span></article>`;
  const files = new Map([
    ['../../Makefile', `APP_VERSION ?= ${stable}\n`],
    ['../../win/src/AQB.App/AQB.App.csproj', `<Project><Version>${windows}</Version></Project>`],
    ['../content/releases.json', JSON.stringify([windowsRelease, stableRelease])],
    ['../wrangler.pages.toml', `[vars]\nAPP_LATEST_VERSION = "${stable}"\n`],
    ['../wrangler.toml', `[vars]\nAPP_LATEST_VERSION = "${stable}"\n`],
  ]);
  for (const dir of ['', 'en/']) {
    files.set(`../public/${dir}index.html`, homepage);
    files.set(`../dist-pages/${dir}index.html`, homepage);
    files.set(`../dist-pages/${dir}changelog.html`, changelog);
  }
  return files;
}
const readFixture = files => async path => {
  assert.ok(files.has(path), `Unexpected fixture path ${path}`);
  return files.get(path);
};

test('deployment gate accepts synchronized dual-platform content with beta listed first', async () => {
  assert.deepEqual(await checkReleaseSite(readFixture(siteFiles())), {stable, windows});
});

test('deployment gate rejects stale versions, links, artifacts and misplaced latest badges', async t => {
  const cases = [
    ['stale stable feed', files => files.set('../content/releases.json', JSON.stringify([windowsRelease, {...stableRelease, tag_name: 'v1.38.5'}])), /Sync the published stable release/],
    ['missing Windows beta', files => files.set('../content/releases.json', JSON.stringify([stableRelease])), /Windows beta must be visible/],
    ['stale Worker fallback', files => files.set('../wrangler.toml', 'APP_LATEST_VERSION = "1.38.5"'), /Worker fallback version/],
    ['stale tracked Worker fallback', files => files.set('../wrangler.pages.toml', 'APP_LATEST_VERSION = "1.38.5"'), /Worker fallback version/],
    ['stale built homepage', files => files.set('../dist-pages/en/index.html', '<p>old build</p>'), /Rebuild Pages/],
    ['missing visible Mac version', files => replaceHome(files, html => html.replace(`v${stable}`, 'old')), /homepage must show current macOS version/],
    ['Mac download on beta', files => replaceHome(files, html => html.replace('/releases/latest/download/', `/releases/download/v${windows}/`)), /stable channel/],
    ['stale Windows URL', files => replaceHome(files, html => html.replace(`download/v${windows}/`, 'download/v1.38.0/')), /outdated Windows download links/],
    ['no Windows download', files => replaceHome(files, html => html.replace(/<a href="[^"]*win-x64.zip">Windows<\/a>/, '')), /Windows ZIP link/],
    ['beta missing from generated notes', files => files.set('../dist-pages/en/changelog.html', `<article id="v${stable}"><span class="latest">Latest macOS stable</span></article>`), /Windows beta missing/],
    ['latest badge incorrectly assigned to beta', files => files.set('../dist-pages/en/changelog.html', `<article id="v${windows}"><span class="latest">Latest macOS stable</span></article><article id="v${stable}"></article>`), /badge must belong/],
    ['duplicate latest badges', files => files.set('../dist-pages/en/changelog.html', `<article id="v${windows}"><span class="latest">Latest macOS stable</span></article><article id="v${stable}"><span class="latest">Latest macOS stable</span></article>`), /Exactly one release/],
  ];
  for (const [name, mutate, message] of cases) {
    await t.test(name, async () => {
      const files = siteFiles();
      mutate(files);
      await assert.rejects(checkReleaseSite(readFixture(files)), message);
    });
  }
});

function replaceHome(files, transform) {
  for (const dir of ['', 'en/']) {
    const html = transform(files.get(`../public/${dir}index.html`));
    files.set(`../public/${dir}index.html`, html);
    files.set(`../dist-pages/${dir}index.html`, html);
  }
}

test('Pages deployment always builds, then enforces the release gate before upload', async () => {
  const pkg = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
  assert.match(pkg.scripts['deploy:pages'], /^npm run build:pages && npm run check:release-site && wrangler pages deploy\b/);
  assert.equal(pkg.scripts['check:release-site'], 'node scripts/check-release-site.mjs');
});

test('Worker fallback uses the configured stable version and PKG when GitHub is unavailable', async t => {
  const config = await readFile(new URL('../wrangler.pages.toml', import.meta.url), 'utf8');
  const version = config.match(/^APP_LATEST_VERSION\s*=\s*"([^"]+)"/m)?.[1];
  assert.ok(version);
  t.mock.method(globalThis, 'fetch', async () => { throw new Error('GitHub unavailable'); });
  for (const env of [{APP_LATEST_VERSION: version}, {}]) {
  const response = await worker.fetch(new Request('https://example.com/v1/app-update'), env);
  const result = await response.json();
  assert.equal(response.status, 200);
  assert.equal(result.source, 'worker-fallback');
  assert.equal(result.version, version);
  assert.equal(result.tag, `v${version}`);
  assert.equal(result.release_url, `${repository}/releases/tag/v${version}`);
  assert.equal(result.download_url, `${repository}/releases/download/v${version}/AIQuotaBar.pkg`);
  assert.equal(result.warning, 'GitHub unavailable');
  }
});
