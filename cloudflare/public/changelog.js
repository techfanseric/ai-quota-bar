const EN = document.documentElement.lang === 'en';
const COUNT_MATCH = c => EN ? `${c} matching releases` : `找到 ${c} 个匹配版本`;
const COUNT_ALL = n => EN ? `${n} releases · Original release notes preserved` : `共 ${n} 个正式版本 · 完整保留原始发布说明`;
const search = document.querySelector('#release-search');
const releases = [...document.querySelectorAll('.release')];
const indexLinks = [...document.querySelectorAll('aside nav a')];
function filter() {
 const query = search.value.trim().toLocaleLowerCase();
 let count = 0;
 releases.forEach((release, i) => { const shown = release.textContent.toLocaleLowerCase().includes(query); release.hidden = !shown; indexLinks[i].hidden = !shown; count += Number(shown); });
 document.querySelector('#release-count').textContent = query ? COUNT_MATCH(count) : COUNT_ALL(releases.length);
 document.querySelector('#empty').hidden = count !== 0;
}
search.addEventListener('input', filter);
function revealHash() { const target = document.getElementById(decodeURIComponent(location.hash.slice(1))); if (target?.classList.contains('release') && target.hidden) { search.value=''; filter(); target.scrollIntoView(); } }
window.addEventListener('hashchange', revealHash);
