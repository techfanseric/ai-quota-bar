// Deterministic, fictional data only. No app, account or telemetry requests.
const NS='http://www.w3.org/2000/svg';
const svgNode=(tag,attrs={},text)=>{const n=document.createElementNS(NS,tag);Object.entries(attrs).forEach(([k,v])=>n.setAttribute(k,v));if(text!==undefined)n.textContent=text;return n;};
function pressed(root,selector,key,value){root.querySelectorAll(selector).forEach(b=>b.setAttribute('aria-pressed',String(b.dataset[key]===value)));}
const base=[132000,62000,187000,108000,221000,98000,136000];
const labels={tokens:'Tokens',records:'用量记录',cache:'缓存命中率',cost:'估算成本'};
const compact=n=>new Intl.NumberFormat('en',{notation:'compact',maximumFractionDigits:1}).format(n);
document.querySelectorAll('[data-usage]').forEach(root=>{
 let range=7,metric='tokens',factor=1,selected=null;
 const chart=root.querySelector('svg');
 function data(){return Array.from({length:range===1?24:range},(_,i)=>({tokens:Math.round((range===7?base[i]:base[i%7]*(range===1?.055:.8+(i%4)*.1))*factor),records:Math.round((range===1?2+i%5:8+i%9)*factor),input:Math.round((range===7?base[i]:base[i%7])*.9*factor),cache:.22+(i%5)*.06,cost:null}));}
 function value(d){return metric==='cache'?d.cache*100:d[metric];}
 function format(v){return v===null?'价格不完整':metric==='cache'?v.toFixed(1)+'%':compact(v);}
 function date(i){return range===1?String(i).padStart(2,'0')+':00':new Date(Date.UTC(2026,8,19-range+i)).toISOString().slice(5,10).replace('-','/');}
 function render(){const rows=data(),tokens=rows.reduce((s,d)=>s+d.tokens,0),records=rows.reduce((s,d)=>s+d.records,0),cache=rows.reduce((s,d)=>s+d.cache*d.input,0)/rows.reduce((s,d)=>s+d.input,0)*100;
 const total=metric==='tokens'?tokens:metric==='records'?records:metric==='cache'?cache:null;
 root.querySelector('[data-value]').textContent=format(selected===null?total:value(rows[selected]));root.querySelector('[data-unit]').textContent=labels[metric];root.querySelector('[data-period]').textContent=selected===null?(range===1?'今天 · 按小时':`近 ${range} 天 · 按天`):date(selected);
 root.querySelector('[data-hint]').textContent=metric==='cost'?`未定价时段留空 · 价格覆盖 0/${records} 条`:'悬停查看历史 · 当前时段尚未结束';
 chart.replaceChildren();const max=metric==='cache'?100:Math.max(1,...rows.map(value).filter(v=>v!==null)),W=309,H=73;
 [0,.5,1].forEach(t=>{chart.append(svgNode('line',{x1:0,x2:W,y1:H-H*t+2,y2:H-H*t+2,class:'chart-grid'}),svgNode('text',{x:315,y:H-H*t+5},compact(max*t)));});
 rows.forEach((d,i)=>{const amount=value(d);if(amount===null)return;const x=(i+.5)*W/rows.length,y=H-amount/max*H+2;chart.append(svgNode(metric==='cache'?'circle':'rect',metric==='cache'?{cx:x,cy:y,r:2,class:'cache-dot'}:{x:x-W/rows.length*.4,y,width:W/rows.length*.8,height:H+2-y,rx:1,class:'usage-bar'}));});
 [0,Math.floor((rows.length-1)/2),rows.length-1].forEach((i,j)=>chart.append(svgNode('text',{x:j===0?0:j===1?W/2:W,y:91,'text-anchor':j===0?'start':j===1?'middle':'end'},date(i))));
 if(selected!==null){const x=(selected+.5)*W/rows.length;chart.append(svgNode('line',{x1:x,x2:x,y1:0,y2:H+2,class:'selection-guide'}));}
 chart.setAttribute('aria-label',`${range===1?'今天':`近 ${range} 天`} ${labels[metric]} · ${format(total)}，左右方向键查看单个时段`);
 if(root.dataset.usage==='settings'){document.querySelector('[data-local-total]').textContent=tokens.toLocaleString('en');document.querySelector('[data-local-records]').textContent=records;document.querySelector('[data-local-cache]').textContent=cache.toFixed(1)+'%';}
 }
 root.querySelectorAll('[data-range]').forEach(b=>b.addEventListener('click',()=>{range=Number(b.dataset.range);selected=null;pressed(root,'[data-range]','range',String(range));render();}));
 root.querySelectorAll('[data-metric]').forEach(b=>b.addEventListener('click',()=>{metric=b.dataset.metric;selected=null;pressed(root,'[data-metric]','metric',metric);render();}));
 chart.addEventListener('pointermove',e=>{const r=chart.getBoundingClientRect(),x=(e.clientX-r.left)/r.width*340;selected=x<=309?Math.min(data().length-1,Math.max(0,Math.floor(x/309*data().length))):null;render();});chart.addEventListener('pointerleave',()=>{selected=null;render();});
 chart.addEventListener('keydown',e=>{if(!['ArrowLeft','ArrowRight','Escape'].includes(e.key))return;e.preventDefault();selected=e.key==='Escape'?null:Math.min(data().length-1,Math.max(0,(selected??0)+(e.key==='ArrowRight'?1:-1)));render();});chart.addEventListener('blur',()=>{selected=null;render();});
 if(root.dataset.usage==='settings')document.querySelector('#history-account').addEventListener('change',e=>{factor={current:1,previous:.48,unknown:.16}[e.target.value];selected=null;render();});render();
});
document.querySelectorAll('[data-quota]').forEach((root,index)=>{
 const weekly=root.dataset.quota==='Weekly',count=weekly?12:24,levels=Array.from({length:count},(_,i)=>[14,35,8,62,21,48,73,35,57,26,46,36][i%12]);
 const chart=root.querySelector('svg'),meta=root.querySelector('[data-quota-meta]'),heading=root.querySelector('.native-model strong');
 function draw(cycle=null){chart.replaceChildren();const percent=cycle===null?(weekly?64:82):100-levels[cycle];heading.textContent=percent+'%';const start=weekly?'09/15 09:00':'08:00',end=weekly?'09/22 09:00':'13:00';
 const points=Array.from({length:22},(_,i)=>[27+i*(cycle===null?(weekly?131.15:146.4):305)/21,7+(100-percent)/100*58*Math.floor(i/3)*3/21]);
 chart.append(svgNode('path',{d:'M27 7V65H332',stroke:'#a0a49a55',fill:'none','stroke-width':.6}));
 chart.append(svgNode('path',{d:'M27 7L332 65',stroke:'#7ea26e','stroke-dasharray':'4 4',fill:'none','stroke-width':1}));
 chart.append(svgNode('path',{d:'M'+points.map(p=>p.join(' ')).join('L')+`L${points.at(-1)[0]} 65L27 65Z`,fill:'#52c56c20'}));chart.append(svgNode('polyline',{points:points.map(p=>p.join(',')).join(' '),fill:'none',stroke:'#35bd58','stroke-width':1.6}));points.forEach(([cx,cy])=>chart.append(svgNode('circle',{cx,cy,r:1.4,fill:'#35bd58'})));
 chart.append(svgNode('text',{x:0,y:11},'100%'),svgNode('text',{x:15,y:67},'0'),svgNode('text',{x:27,y:80},cycle===null?start:`第 ${cycle+1} 个历史周期`),svgNode('text',{x:332,y:80,'text-anchor':'end'},cycle===null?end:'周期结束'));
 meta.textContent=cycle===null?(weekly?'盈余 7% · 09/22 09:00':'盈余 30% · 13:00'):`历史周期 · 峰值使用 ${levels[cycle]}%`;
 }
 levels.forEach((n,i)=>{const b=document.createElement('button');b.type='button';b.setAttribute('aria-label',`${root.dataset.quota} 第 ${i+1} 个历史周期，使用 ${n}%`);const bar=document.createElement('i');bar.style.setProperty('--cycle-level',n+'%');b.append(bar);b.addEventListener('mouseenter',()=>draw(i));b.addEventListener('focus',()=>draw(i));b.addEventListener('click',()=>draw(i));b.addEventListener('mouseleave',()=>draw());b.addEventListener('blur',()=>draw());root.querySelector('.cycles').append(b);});draw();
});
const modelRows=[...document.querySelectorAll('[data-model]')],account=document.querySelector('#demo-account');
function renderSettings(){const selected=modelRows.filter(r=>r.querySelector('[data-mobile]').checked).length;let visible=0;modelRows.forEach(row=>{const menu=row.querySelector('[data-menu]'),mobile=row.querySelector('[data-mobile]');menu.disabled=!account.checked;mobile.disabled=mobile.checked?selected<=1:selected>=2;mobile.title=mobile.disabled?(mobile.checked?'至少保留一项':'请先取消另一项'):'在手机看板显示';if(account.checked&&menu.checked)visible++;});document.querySelector('#menu-count').textContent=`菜单 · 显示 ${visible} / 3`;document.querySelector('#mobile-count').textContent=`手机 · 已选择 ${selected}/2`;document.querySelector('#show-all').disabled=account.checked&&modelRows.every(r=>r.querySelector('[data-menu]').checked);document.querySelector('#selection-help').textContent='账号开关保留各模型选择。手机保留 1–2 项；隐藏不影响采集、历史、告警或同步。';}
document.querySelectorAll('.settings-table input,.settings-table select').forEach(c=>c.addEventListener('change',renderSettings));document.querySelector('#show-all').addEventListener('click',()=>{account.checked=true;modelRows.forEach(r=>r.querySelector('[data-menu]').checked=true);renderSettings();});renderSettings();
const map=document.querySelector('#connection-map');[0,7,14].forEach(n=>map.append(svgNode('text',{x:4,y:108-n*6.5,fill:'#8c9285','font-size':9},n)));for(let i=0;i<60;i++){const count=4+Math.round(3*(1+Math.sin(i*.22)))+(i%7===0?2:0);for(let j=0;j<count;j++){map.append(svgNode('rect',{x:26+i*6.4,y:100-j*6.5,width:4.6,height:4.6,rx:1.3,fill:j<2&&i>35?'#d69b31':'#42bf60'}));}}[['−60m',26],['−30m',205],['now',386]].forEach(([label,x])=>map.append(svgNode('text',{x,y:127,fill:'#8c9285','font-size':9},label)));
window.addEventListener('message',event=>{const frame=document.getElementById('mobile-preview');if(event.source===frame.contentWindow&&event.data?.type==='aqb-preview-ready')frame.dataset.ready='true';});
