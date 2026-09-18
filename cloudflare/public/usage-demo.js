import {usageFixture,intensity,DEMO_NOW} from './usage-fixture.js';
const en=document.documentElement.lang==='en';const t=(zh,enText)=>en?enText:zh;
const labels={tokens:'Tokens',records:t('用量记录','Records'),cache:t('缓存命中','Cache hit'),cost:t('估算成本','Est. cost')};
const compact=n=>new Intl.NumberFormat(en?'en':'zh-CN',{notation:'compact',maximumFractionDigits:1}).format(n);
const clock=d=>`${String(d.getHours()).padStart(2,'0')}:${String(d.getMinutes()).padStart(2,'0')}`;
const date=d=>`${String(d.getMonth()+1).padStart(2,'0')}/${String(d.getDate()).padStart(2,'0')}`;
// Reset history from codex-resets.com (public API, no key). Frames mark announced reset days in the demo month.
const monthResets=new Map();const resetTypes=day=>monthResets.get(day.getDate())||[];
const resetsReady=fetch('https://codex-resets.com/api/v1/resets?limit=100').then(r=>r.ok?r.json():{data:[]}).then(({data})=>{
 for(const item of data||[]){const day=new Date(item.announced_at);if(day.getFullYear()===DEMO_NOW.getFullYear()&&day.getMonth()===DEMO_NOW.getMonth()){const list=monthResets.get(day.getDate())||[];if(!list.some(x=>x.reset_type===item.reset_type))list.push(item);monthResets.set(day.getDate(),list);}}
}).catch(()=>{});
for(const root of document.querySelectorAll('[data-usage]')) {
 const menu=root.dataset.usage==='menu';let metric='tokens',account=menu?'current':'all',data=usageFixture(account);
 function format(value){return value==null?t('未定价','Unpriced'):metric==='cache'?value.toFixed(1)+'%':metric==='cost'?'$'+value.toFixed(4):compact(value);}
 function render(){
  data=usageFixture(account);
  const resetsBadge=monthResets.size?`<a class="usage-resets" href="https://codex-resets.com" title="${t('重置记录来自 Codex Resets','Reset history from Codex Resets')}">${en?monthResets.size+' resets':'重置 ×'+monthResets.size}</a>`:'';
  const available=Object.keys(labels).filter(k=>k!=='cost'||[...data.daily,...data.hourly].some(b=>b.records>0&&b.cost!==null));
  if(!available.includes(metric))metric='tokens';
  root.innerHTML=`<div class="usage-metrics">${menu?`<span class="local-badge">${t('本机','Local')}</span>`:''}${available.map(k=>`<button type="button" data-metric="${k}" aria-pressed="${metric===k}">${labels[k]}</button>`).join('')}</div><div class="usage-grids"><div class="usage-month"><div class="usage-grid-heading"><span>${new Intl.DateTimeFormat(en?'en-US':'zh-CN',{month:'short'}).format(data.now)}</span>${resetsBadge}</div><div class="month-matrix" aria-label="${t('本月每日用量','Daily usage this month')}"></div></div><div class="usage-recent"><div class="usage-grid-heading"><span>${t('近 24h','Last 24h')}</span><span>${t('每格 5m','5m / cell')}</span></div><div class="recent-matrix" aria-label="${t('最近24小时，每格5分钟','Last 24 hours, 5 minutes per cell')}"></div></div></div><div class="usage-summary" aria-live="polite"></div><div class="usage-callout" hidden></div>`;
  const summary=root.querySelector('.usage-summary'),callout=root.querySelector('.usage-callout');
  const pair=(label,value)=>`<span>${label} <strong>${format(value)}</strong></span>`;
  const reset=()=>{summary.innerHTML=pair(t('本月','Month'),data.total[metric])+pair(t('近 24h','Last 24h'),data.recent[metric]);callout.hidden=true;};
  function cell(bucket,max,recent=false){
   const b=document.createElement('button');b.type='button';const value=bucket[metric],level=intensity(value,max);b.className='usage-cell';
   b.style.background=level==null||level===0?'rgba(0,0,0,.07)':`rgba(52,199,89,${level*.8})`;
   if(level==null)b.classList.add('unpriced');
   const renewal=!recent&&bucket.start.getDate()===data.renewalDay;
   const future=!recent&&bucket.start>data.now;b.disabled=future&&!renewal;if(future&&!renewal)b.classList.add('future');
   if(renewal)b.classList.add('renewal');
   const resets=!recent?resetTypes(bucket.start):[];
   if(resets.length)b.classList.add('reset');
   const when=date(bucket.start)+(recent?' '+clock(bucket.start)+'–'+clock(bucket.end):'');
   const resetAt=resets[0]?clock(new Date(resets[0].announced_at))+t(' 已重置',' reset'):''; // 列表最新在前，取当天最近一次
   const detail=when+(future?'':' · '+format(value)+' '+labels[metric])+(renewal?' · '+t('自动续费','Auto-renews'):'')+(resetAt?' · '+resetAt:'');b.setAttribute('aria-label',detail);
   const select=()=>{if(!future)summary.innerHTML=pair(when,value)+`<span>${labels[metric]}</span>`;callout.textContent=detail;callout.hidden=false;callout.classList.toggle('recent',recent);
    const host=root.getBoundingClientRect(),r=b.getBoundingClientRect(),half=Math.min(90,host.width/2),gridTop=b.closest('.month-matrix,.recent-matrix').offsetTop,below=r.top-host.top-19<gridTop;
    callout.style.left=Math.min(Math.max(r.left-host.left+r.width/2,half),host.width-half)+'px';callout.style.right='auto';
    callout.style.top=(below?r.bottom-host.top+4:r.top-host.top-4)+'px';callout.style.transform=below?'translateX(-50%)':'translate(-50%,-100%)';};
   b.addEventListener('mouseenter',select);b.addEventListener('mouseleave',reset);b.addEventListener('focus',select);b.addEventListener('blur',reset);b.addEventListener('click',select);return b;
  }
  const matrix=root.querySelector('.month-matrix'),offset=data.daily[0].start.getDay();
  for(let i=0;i<offset;i++){const blank=document.createElement('span');blank.setAttribute('aria-hidden','true');matrix.append(blank);}
  const maximum=metric==='cache'?100:Math.max(1,...data.daily.map(d=>d[metric]||0));data.daily.forEach(b=>matrix.append(cell(b,maximum)));
  const recent=root.querySelector('.recent-matrix'),recentMax=metric==='cache'?100:Math.max(1,...data.hourly.map(d=>d[metric]||0));
  for(let column=0;column<24;column++){
   const wrap=document.createElement('div');wrap.className='hour-column';
   for(let i=0;i<12;i++)wrap.append(cell(data.hourly[column*12+i],recentMax,true));
   const tick=document.createElement('span');tick.className='hour-tick';tick.textContent=column%2===0?String(data.hourly[column*12].start.getHours()).padStart(2,'0'):' ';wrap.append(tick);recent.append(wrap);
  }
  root.querySelectorAll('[data-metric]').forEach(b=>b.addEventListener('click',()=>{metric=b.dataset.metric;render();}));reset();
  if(!menu){
   const panel=root.closest('.local-settings'),s=data.total,number=n=>n.toLocaleString(en?'en-US':'zh-CN');
   panel.querySelector('[data-local-totals]').innerHTML=[['Tokens',number(s.tokens)],[t('有效用量记录','Usage records'),number(s.records)],[t('缓存命中率','Cache hit rate'),s.cache.toFixed(1)+'%'],[t('估算成本','Estimated cost'),t('未定价','Unpriced')]].map(([k,v])=>`<div><span>${k}</span><strong>${v}</strong></div>`).join('');
   panel.querySelector('[data-local-details]').innerHTML=`<p>${t('输入','Input')} ${number(s.input)} · ${t('输出','Output')} ${number(s.output)} · ${t('缓存读取','Cache read')} ${number(s.cached)} · ${t('缓存写入','Cache write')} 0</p><p>${t(`价格覆盖 0/${s.records} 条；0 条为累计差值。成本为 API 等价估算，用量记录不等于完整 HTTP 请求数。`,`Prices cover 0/${s.records} records; 0 use cumulative deltas. Costs are API-equivalent estimates; records are not complete HTTP request counts.`)}</p><div class="usage-model"><span>gpt-5.4</span><span>${number(s.tokens)} tokens</span></div><p>${t('扫描 12 个文件 · 0 个异常 · 0 个会话待解析 · 0 个尾行待写完','12 files · 0 issues · 0 deferred sessions · 0 incomplete tails')}</p><p>${t('最近扫描：','Last scan: ')}09/18/2026 10:24</p><span class="native-button">${t('导入模型价格 JSON…','Import model prices JSON…')}</span>`;
  }
 }
 if(!menu){const picker=document.querySelector('#history-account');picker.options[0].value='all';picker.options[1].value='current';picker.addEventListener('change',()=>{account=picker.value;render();});}
 render();
 resetsReady.then(()=>{if(monthResets.size)render();});
}
