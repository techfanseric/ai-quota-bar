// Deterministic, fictional data only. No app, account or telemetry requests.
const NS='http://www.w3.org/2000/svg';
const svgNode=(tag,attrs={},text)=>{const n=document.createElementNS(NS,tag);Object.entries(attrs).forEach(([k,v])=>n.setAttribute(k,v));if(text!==undefined)n.textContent=text;return n;};
function pressed(root,selector,key,value){root.querySelectorAll(selector).forEach(b=>b.setAttribute('aria-pressed',String(b.dataset[key]===value)));}
const base=[132000,62000,187000,108000,221000,98000,136000];
const labels={tokens:'Tokens',records:'用量记录',cache:'缓存命中率',cost:'估算成本'};
const compact=n=>new Intl.NumberFormat('en',{notation:'compact',maximumFractionDigits:1}).format(n);
document.querySelectorAll('[data-usage]').forEach(root=>{
 let metric='tokens',factor=1;
 const matrix=root.querySelector('.activity-matrix'),hours=root.querySelector('.activity-hours');
 const daily=Array.from({length:30},(_,i)=>({tokens:base[i%7]*(.8+i%4*.1),records:8+i%9,cache:22+i%5*6,cost:null}));
 function format(v){return v===null?'未定价':metric==='cache'?v.toFixed(1)+'%':compact(v);}
 function show(v,label){root.querySelector('[data-value]').textContent=format(v);root.querySelector('[data-unit]').textContent=labels[metric];root.querySelector('[data-period]').textContent=label;}
 function total(){return metric==='cost'?null:metric==='cache'?daily.reduce((s,d)=>s+d.cache*d.tokens,0)/daily.reduce((s,d)=>s+d.tokens,0):daily.reduce((s,d)=>s+d[metric]*factor,0);}
 function bar(parent,amount,max,label,isHour=false){const b=document.createElement('button');b.type='button';b.setAttribute('aria-label',label+' · '+format(amount));b.title=label+' · '+format(amount);if(isHour){const i=document.createElement('i');i.style.height=amount===null?'0':Math.max(2,amount/max*100)+'%';b.append(i);}else{b.style.background=amount===null?'repeating-linear-gradient(135deg,#ddd 0 1px,#eee 1px 4px)':['#edf0ed','#c5e5cc','#9dd5aa','#6fc181','#39a953'][Math.min(4,Math.ceil(amount/max*4))];}
 const enter=()=>show(amount,label),leave=()=>show(total(),'近 30 天');b.addEventListener('mouseenter',enter);b.addEventListener('focus',enter);b.addEventListener('mouseleave',leave);b.addEventListener('blur',leave);parent.append(b);}
 function render(){matrix.replaceChildren();hours.replaceChildren();const max=metric==='cache'?100:Math.max(1,...daily.map(d=>(d[metric]||0)*factor));for(let i=0;i<4;i++){const empty=document.createElement('span');empty.className='empty';matrix.append(empty);}daily.forEach((d,i)=>bar(matrix,d[metric]===null?null:d[metric]*(metric==='cache'?1:factor),max,new Date(Date.UTC(2026,7,20+i)).toISOString().slice(5,10).replace('-','/')));
 for(let i=0;i<11;i++)bar(hours,metric==='cost'?null:metric==='cache'?22+i%5*6:daily[i%30][metric]*factor/10,max/(metric==='cache'?1:8),String(i).padStart(2,'0')+':00',true);for(let i=11;i<24;i++){const future=document.createElement('button');future.disabled=true;future.setAttribute('aria-label',String(i).padStart(2,'0')+':00 · 尚未开始');hours.append(future);}
 show(total(),'近 30 天');root.querySelector('[data-hint]').textContent=metric==='cost'?'未配置单价的时段保留为未定价':'悬停查看每日或每小时用量';
 if(root.dataset.usage==='settings'){document.querySelector('[data-local-total]').textContent=Math.round(daily.reduce((s,d)=>s+d.tokens*factor,0)).toLocaleString('en');document.querySelector('[data-local-records]').textContent=Math.round(daily.reduce((s,d)=>s+d.records*factor,0));document.querySelector('[data-local-cache]').textContent='34.2%';}}
 root.querySelectorAll('[data-metric]').forEach(b=>b.addEventListener('click',()=>{metric=b.dataset.metric;pressed(root,'[data-metric]','metric',metric);render();}));
 if(root.dataset.usage==='settings')document.querySelector('#history-account').addEventListener('change',e=>{factor={current:1,previous:.48,unknown:.16}[e.target.value];render();});render();
});
document.querySelectorAll('.mini-connection-map').forEach(root=>{for(let i=0;i<48;i++){const bar=document.createElement('i');bar.style.height=(20+(i*17)%45)+'px';root.append(bar);}});
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
window.addEventListener('message',event=>{document.querySelectorAll('iframe').forEach(frame=>{if(event.source===frame.contentWindow&&event.data?.type==='aqb-preview-ready')frame.dataset.ready='true';});});
