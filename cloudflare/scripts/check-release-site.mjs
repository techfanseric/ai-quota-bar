import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Run after sync:releases + build:pages. Deployment must not publish stale links.
const defaultRead = path => readFile(new URL(path, import.meta.url), 'utf8');
export async function checkReleaseSite(read = defaultRead) {
const makefile = await read('../../Makefile');
const stable = makefile.match(/^APP_VERSION\s*\?=\s*(\S+)/m)?.[1];
assert.ok(stable, 'Makefile must declare APP_VERSION');
const csproj = await read('../../win/src/AQB.App/AQB.App.csproj');
const windows = csproj.match(/<Version>([^<]+)<\/Version>/)?.[1];
assert.ok(windows, 'Windows project must declare Version');
const releases = JSON.parse(await read('../content/releases.json'));
assert.equal(releases.find(r => !r.prerelease)?.tag_name, `v${stable}`, 'Sync the published stable release before deployment');
assert.ok(releases.some(r => r.tag_name === `v${windows}` && r.prerelease), 'Windows beta must be visible in the changelog');
for (const config of ['wrangler.pages.toml', 'wrangler.toml']) {
  assert.match(await read(`../${config}`), new RegExp(`APP_LATEST_VERSION = "${stable.replaceAll('.', '\\.')}"`), `Update the Worker fallback version in ${config}`);
}
for (const dir of ['', 'en/']) {
  const source = await read(`../public/${dir}index.html`);
  const built = await read(`../dist-pages/${dir}index.html`);
  assert.equal(built, source, 'Rebuild Pages after editing homepage content');
  assert.ok(source.includes(`v${stable}`), `${dir}homepage must show current macOS version`);
  assert.ok(source.includes('/releases/latest/download/AIQuotaBar.pkg'), 'Keep macOS downloads on the stable channel');
  const winLinks = [...source.matchAll(/href="([^"]*\/releases\/download\/[^\"]*win-x64\.zip)"/g)].map(m => m[1]);
  assert.ok(winLinks.length >= 1, 'Provide a Windows ZIP link');
  assert.ok(winLinks.every(link => link === `https://github.com/techfanseric/ai-quota-bar/releases/download/v${windows}/AIQuotaBar-win-x64.zip`), 'Remove outdated Windows download links');
  const changelog = await read(`../dist-pages/${dir}changelog.html`);
  assert.ok(changelog.includes(`id="v${stable}"`), 'Stable release missing from generated changelog');
  assert.ok(changelog.includes(`id="v${windows}"`), 'Windows beta missing from generated changelog');
  assert.equal((changelog.match(/<span class="latest">(?:最新 macOS 正式版|Latest macOS stable)<\/span>/g) || []).length, 1, 'Exactly one release gets the latest stable badge');
 const stableArticle = [...changelog.matchAll(/<article\b[^>]*id="([^"]+)"[^>]*>([\s\S]*?)<\/article>/g)]
  .find(article => article[1] === `v${stable}`)?.[2];
 assert.match(stableArticle || '', /<span class="latest">(?:最新 macOS 正式版|Latest macOS stable)<\/span>/, 'Latest stable badge must belong to the current macOS release');
}
return {stable, windows};
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
 const {stable, windows} = await checkReleaseSite();
 console.log(`Release website checks passed: macOS v${stable}; Windows v${windows}.`);
}
