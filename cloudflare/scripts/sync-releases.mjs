// Run before publishing the website: npm run sync:releases (requires gh auth).
import { execFileSync } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export function prepareReleaseHistory(pages, existingReleases = []) {
 const existing = new Map(existingReleases.map(r => [r.tag_name, r]));
 const releases = pages.flat().filter(r => !r.draft)
  .sort((a, b) => b.published_at.localeCompare(a.published_at))
  .map(({tag_name, name, published_at, html_url, body, prerelease, assets}) => ({
   tag_name, name, published_at, html_url, body, prerelease,
   platform: assets?.some(a => /win-x64/i.test(a.name)) ? 'windows' : 'macos',
   ...Object.fromEntries(['name_en', 'body_en', 'name_zh', 'body_zh']
    .filter(key => existing.get(tag_name)?.[key])
    .map(key => [key, existing.get(tag_name)[key]])),
  }));
 if (!releases.some(r => !r.prerelease)) throw new Error('No published stable releases; refusing to replace history.');
 return releases;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
 const existing = JSON.parse(await readFile('content/releases.json', 'utf8'));
 const pages = JSON.parse(execFileSync('gh', ['api', '--paginate', '--slurp', 'repos/techfanseric/ai-quota-bar/releases'], {encoding: 'utf8'}));
 const releases = prepareReleaseHistory(pages, existing);
 await writeFile('content/releases.json', JSON.stringify(releases, null, 2) + '\n');
 console.log(`Synced ${releases.length} published releases.`);
}
