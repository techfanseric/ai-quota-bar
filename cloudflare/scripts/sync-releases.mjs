// Run before publishing the website: npm run sync:releases (requires gh auth).
import { execFileSync } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';
const existing = new Map(JSON.parse(await readFile('content/releases.json','utf8')).map(r=>[r.tag_name,r]));
const pages = JSON.parse(execFileSync('gh', ['api','--paginate','--slurp','repos/techfanseric/ai-quota-bar/releases'], {encoding:'utf8'}));
const releases = pages.flat().filter(r=>!r.draft&&!r.prerelease).sort((a,b)=>b.published_at.localeCompare(a.published_at)).map(({tag_name,name,published_at,html_url,body})=>({tag_name,name,published_at,html_url,body,...Object.fromEntries(['name_en','body_en','name_zh','body_zh'].filter(key=>existing.get(tag_name)?.[key]).map(key=>[key,existing.get(tag_name)[key]]))}));
if (!releases.length) throw new Error('No published releases; refusing to replace history.');
await writeFile('content/releases.json',JSON.stringify(releases,null,2)+'\n');
console.log(`Synced ${releases.length} published releases.`);
