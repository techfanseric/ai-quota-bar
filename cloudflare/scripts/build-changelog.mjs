import { readFile, writeFile } from 'node:fs/promises';
import { Marked } from 'marked';
export const escape = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const markdown = new Marked({ renderer: {
  html({text}) { return escape(text); },
  link({href,tokens}) { const label = this.parser.parseInline(tokens); return /^https?:\/\//i.test(href) ? `<a href="${escape(href)}" rel="noopener noreferrer">${label}</a>` : label; },
  image({text}) { return escape(text); },
}});
const VARIANTS=[
 {dir:'',here:'zh',switchTo:'en',lang:'zh-CN',href:'https://ai-quota-bar.pages.dev/changelog',altPath:'/en/changelog',
  title:'更新日志 — AI Quota Bar',desc:'AI Quota Bar 完整版本更新记录，从 v1.0.0 至今的功能、改进与修复。',
  skip:'跳到更新日志',backHome:'返回首页',download:'下载最新版 ↗',heading:'每一次，让它更好用。',
  intro:'从菜单栏里的一个数字，到看得见的使用趋势。这里记录每个正式版本的变化。',
  searchLabel:'查找版本或功能',searchPlaceholder:'例如：Codex、手机、v1.16.0',
  count:c=>`共 ${c} 个正式版本 · 完整保留原始发布说明`,latest:'最新版本',
  source:'在 GitHub 查看版本与下载附件 ↗',allVersions:'所有版本',ariaIndex:'版本索引',ariaReleases:'版本记录',ariaNav:'主导航',
  empty:'没有匹配的版本，请尝试其他关键词。',backTop:'← 回到产品首页',footerNote:'历史说明保留当时的产品名称与功能状态。',
  altLabel:'EN'},
 {dir:'en/',here:'en',switchTo:'zh',lang:'en',href:'https://ai-quota-bar.pages.dev/en/changelog',altPath:'/changelog',
  title:'Changelog — AI Quota Bar',desc:'Full release history for AI Quota Bar — features, improvements and fixes from v1.0.0 to today.',
  skip:'Skip to the changelog',backHome:'Home',download:'Download latest ↗',heading:'Every release, a little better.',
  intro:'From a number in the menu bar to visible usage trends — every official release is documented here.',
  searchLabel:'Search versions or features',searchPlaceholder:'e.g. Codex, mobile, v1.16.0',
  count:c=>`${c} releases · Original release notes preserved`,latest:'Latest',
  source:'View this release on GitHub ↗',allVersions:'All versions',ariaIndex:'Version index',ariaReleases:'Release notes',ariaNav:'Main navigation',
  empty:'No matching releases — try different keywords.',backTop:'← Back to the homepage',footerNote:'Historical notes keep the product names and features of their time.',
  altLabel:'中文'},
];
const redirectScript=v=>`(function(){try{var k='aqb-lang',here='${v.here}',saved=localStorage.getItem(k);if(saved&&saved!==here){location.replace('${v.altPath}');return}if(!saved){var n=(navigator.languages&&navigator.languages[0])||navigator.language||'';var want=/^zh/i.test(n)?'zh':'en';if(want!==here){localStorage.setItem(k,want);location.replace('${v.altPath}')}}}catch(e){}})();`;
export async function buildChangelog() {
 const releases = JSON.parse(await readFile('content/releases.json','utf8'));
 for (const v of VARIANTS) {
  const en = v.here === 'en';
  const localized = en ? releases.map(r => ({ ...r, name: r.name_en || r.name, body: r.body_en || r.body })) : releases.map(r => ({ ...r, name: r.name_zh || r.name, body: r.body_zh || r.body }));
  const items = localized.map((r,i) => `<article class="release" id="${escape(r.tag_name)}" data-version="${escape(r.tag_name)}"><header><div><a class="version" href="#${escape(r.tag_name)}">${escape(r.tag_name)}</a>${i===0?`<span class="latest">${v.latest}</span>`:''}</div><time datetime="${escape(r.published_at)}">${r.published_at.slice(0,10)}</time></header><h2>${escape(r.name || r.tag_name)}</h2><div class="release-body">${markdown.parse(r.body)}</div><a class="source-link" href="${escape(r.html_url)}">${v.source}</a></article>`).join('\n');
  const nav = releases.map(r=>`<a href="#${escape(r.tag_name)}">${escape(r.tag_name)}</a>`).join('');
  await writeFile(`dist-pages/changelog-locale-${v.here}.js`,redirectScript(v));
  await writeFile(`dist-pages/${v.dir}changelog.html`, `<!doctype html><html lang="${v.lang}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${v.title}</title><meta name="description" content="${v.desc}"><link rel="canonical" href="${v.href}"><link rel="alternate" hreflang="zh-CN" href="https://ai-quota-bar.pages.dev/changelog"><link rel="alternate" hreflang="en" href="https://ai-quota-bar.pages.dev/en/changelog"><link rel="alternate" hreflang="x-default" href="https://ai-quota-bar.pages.dev/changelog"><link rel="icon" href="/favicon.svg"><link rel="stylesheet" href="/site.css"><link rel="stylesheet" href="/changelog.css"><script src="/changelog-locale-${v.here}.js"></script><script src="/language-links.js" defer></script><script src="/changelog.js" defer></script></head><body><a class="skip" href="#main">${v.skip}</a><header class="site-header wrap"><a class="brand" href="/${v.dir}"><img src="/app-icon.png" alt="" width="34" height="34">AI Quota Bar</a><nav aria-label="${v.ariaNav}"><a href="/${v.dir}">${v.backHome}</a><a class="lang-switch" href="${v.altPath}" data-language="${v.switchTo}">${v.altLabel}</a><a class="nav-download changelog-link" href="https://github.com/techfanseric/ai-quota-bar/releases/latest">${v.download}</a></nav></header><main id="main" class="wrap"><section class="changelog-heading"><p class="eyebrow">RELEASE NOTES</p><h1>${v.heading}</h1><p>${v.intro}</p><label for="release-search">${v.searchLabel}</label><input id="release-search" type="search" placeholder="${v.searchPlaceholder}" autocomplete="off"><p id="release-count" role="status">${v.count(releases.length)}</p></section><div class="changelog-layout"><aside aria-label="${v.ariaIndex}"><p>${v.allVersions}</p><nav>${nav}</nav></aside><section class="releases" aria-label="${v.ariaReleases}">${items}<p id="empty" hidden>${v.empty}</p></section></div></main><footer class="site-footer wrap"><a href="/${v.dir}">${v.backTop}</a><span>${v.footerNote}</span></footer></body></html>`);
 }
}
