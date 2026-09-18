// Deterministic, fictional data only. No app, account or telemetry requests.
// Renderers mirror the SwiftUI implementations: CodexUsageActivityView,
// QuotaAreaChart, ModelUtilizationBarsView and ClashConnectionActivityChart.
const NS='http://www.w3.org/2000/svg';
const GREEN='#34c759',SECONDARY='#6c6c71';
const svgNode=(tag,attrs={},text)=>{const n=document.createElementNS(NS,tag);Object.entries(attrs).forEach(([k,v])=>n.setAttribute(k,v));if(text!==undefined)n.textContent=text;return n;};
const EN=document.documentElement.lang==='en';
const STR={
 records:EN?'Records':'用量记录',cache:EN?'Cache hit':'缓存命中',cost:EN?'Est. cost':'估算成本',
 total:EN?'30-day total':'近 30 天合计',
 unpriced:EN?'Unpriced / coverage 0/84 records':'斜线为未定价 · 覆盖 0/84 条',
 upcoming:EN?'Upcoming':'尚未到来',
 menuCount:(v,t)=>EN?`Menu · Showing ${v} / ${t}`:`菜单 · 显示 ${v} / ${t}`,
 mobileCount:n=>EN?`Mobile · ${n}/2 selected`:`手机 · 已选择 ${n}/2`,
 help:EN?'Account switches preserve individual model choices. Select 1–2 models for mobile; Automatic uses the default chart rules. Hiding items does not affect collection, history, alerts or sync.':'账号行的菜单开关会保留各模型的选择。手机看板保留 1–2 项；图表选“自动”沿用默认规则。隐藏不影响采集、历史、告警或同步。',
 atLeastOne:EN?'At least one model must remain selected.':'至少需要保留一个已选模型。',
 deselectFirst:EN?'Deselect another model before selecting this one.':'请先取消选择另一个模型。',
 controlsMobile:EN?'Controls whether this model appears on the read-only mobile dashboard.':'控制该模型是否显示在只读手机看板上。',
 cycleAria:(name,left)=>EN?`${name} past cycle, ${left}% left`:`${name} 历史周期，余 ${left}%`,
};
function pressed(root,selector,key,value){root.querySelectorAll(selector).forEach(b=>b.setAttribute('aria-pressed',String(b.dataset[key]===value)));}
const ageColor=age=>{const t=Math.min(Math.max(age/3600,0),1),a=[.2,.78,.35],b=[1,.49,.05];return `rgb(${a.map((c,i)=>Math.round((c+(b[i]-c)*t)*255)).join(',')})`;};

/* ---- 额度图表：QuotaAreaChart + ModelUtilizationBarsView ---- */
const quotaSpecs={
 '5h':{remaining:82,start:'08:00',end:'13:00',startLong:'09/18 08:00',endLong:'09/18 13:00',cycles:24,
       levels:[14,35,8,62,21,48,73,35,57,26,46,36,18,40,12,55,29,44,9,33,51,24,38,20]},
 Weekly:{remaining:64,start:'09/15 09:00',end:'09/22 09:00',startLong:'09/15 09:00',endLong:'09/22 09:00',cycles:12,
       levels:[48,62,21,55,35,73,40,57,26,46,64,33]}};
const PLOT={x:30,y:8,w:218,h:58,bottom:66,right:248,labelY:79};
function curvePoints(target,noise,fraction=1){ // remaining % over window, from ~100 down to target
 const pts=[];const n=14;
 for(let i=0;i<=n;i++){const t=i/n;const v=100+(target-100)*Math.pow(t,.92)+(noise(i)-.5)*2.2;
  pts.push([PLOT.x+PLOT.w*t*fraction,Math.min(PLOT.bottom,PLOT.y+PLOT.h*(1-Math.max(2,Math.min(100,v))/100))]);}
 return pts;}
function drawQuotaChart(chart,spec,cycle=null){
 chart.replaceChildren();
 const id=chart.dataset.clip||'qg';
 const defs=svgNode('defs');const grad=svgNode('linearGradient',{id,x1:0,y1:0,x2:0,y2:1});
 grad.append(svgNode('stop',{offset:'0','stop-color':GREEN,'stop-opacity':'.22'}),svgNode('stop',{offset:'1','stop-color':GREEN,'stop-opacity':'.03'}));
 defs.append(grad);chart.append(defs);
 // 坐标轴：primary 0.14
 chart.append(svgNode('path',{d:`M${PLOT.x} ${PLOT.y}V${PLOT.bottom}H${PLOT.right}`,stroke:'rgba(0,0,0,.14)','fill':'none','stroke-width':1}));
 // 时间刻度：小时/自然日，虚线 primary 0.10
 const tickCount=spec.cycles===12?7:5;
 for(let i=1;i<tickCount;i++){const x=PLOT.x+PLOT.w*i/tickCount;
  chart.append(svgNode('path',{d:`M${x} ${PLOT.y}V${PLOT.bottom}`,stroke:'rgba(0,0,0,.10)','fill':'none','stroke-width':1,'stroke-dasharray':'2 3'}));}
 // 节奏参考线：余量（behind）→ 绿色 0.55 虚线
 if(cycle===null)chart.append(svgNode('path',{d:`M${PLOT.x} ${PLOT.y}L${PLOT.right} ${PLOT.bottom}`,stroke:GREEN,'stroke-opacity':.55,'stroke-dasharray':'3 3','fill':'none','stroke-width':1}));
 // 序列：曲线画剩余，颜色按该周期的已用峰值判定告警色
 const target=cycle===null?spec.remaining:cycle.left;
 const usedPercent=cycle===null?100-spec.remaining:cycle.used;
 const used=usedPercent>=100?'#ff3b30':usedPercent>=80?'#ff9500':GREEN;
 const noise=i=>((i*7)%11)/11;
 const fraction=cycle===null?(spec.cycles===12?.436904762:.48):1;
 const pts=curvePoints(target,noise,fraction);
 chart.append(svgNode('path',{d:`M${pts[0][0]} ${PLOT.bottom}L${pts.map(p=>p.join(' ')).join('L')}L${pts.at(-1)[0]} ${PLOT.bottom}Z`,fill:`url(#${id})`}));
 chart.append(svgNode('polyline',{points:pts.map(p=>p.join(',')).join(' '),fill:'none',stroke:used,'stroke-width':2,'stroke-linecap':'round','stroke-linejoin':'round'}));
 pts.forEach(([cx,cy])=>chart.append(svgNode('circle',{cx,cy,r:2,fill:used})));
 // 消耗预测：5 4 虚线，0.62
 const last=pts.at(-1);
 if(cycle===null)chart.append(svgNode('path',{d:`M${last[0]} ${last[1]}L${PLOT.right} ${Math.min(PLOT.bottom,PLOT.y+PLOT.h*(1-(100-(100-target)/fraction)/100))}`,stroke:used,'stroke-opacity':.62,'stroke-dasharray':'5 4','fill':'none','stroke-width':1,'stroke-linecap':'round'}));
 // 轴标签：9pt rounded secondary
 chart.append(svgNode('text',{x:3,y:PLOT.y+9},'100%'),svgNode('text',{x:3,y:PLOT.bottom+3},'0'));
 chart.append(svgNode('text',{x:PLOT.x,y:PLOT.labelY},cycle===null?spec.start:cycle.start),svgNode('text',{x:PLOT.right,y:PLOT.labelY,'text-anchor':'end'},cycle===null?spec.end:cycle.end));
}
document.querySelectorAll('[data-quota]').forEach((root,index)=>{
 const spec=quotaSpecs[root.dataset.quota];if(!spec)return;
 const chart=root.querySelector('svg'),barsRoot=root.querySelector('.cycles');
 chart.dataset.clip='quota-grad-'+index;
 const fmt=(d)=>`${String(d.getMonth()+1).padStart(2,'0')}/${String(d.getDate()).padStart(2,'0')} ${String(d.getHours()).padStart(2,'0')}:00`;
 function cycleWindow(i){
  const end=new Date(2026,8,spec.cycles===12?15:18,spec.cycles===12?9:8,0);
  const durationMs=spec.cycles===12?7*864e5:5*36e5;
  const cycleEnd=new Date(end.getTime()-(spec.levels.length-1-i)*durationMs),cycleStart=new Date(cycleEnd.getTime()-durationMs);
  return{start:fmt(cycleStart),end:fmt(cycleEnd),left:100-spec.levels[i],used:spec.levels[i]};
 }
 function draw(cycleIndex=null){drawQuotaChart(chart,spec,cycleIndex===null?null:cycleWindow(cycleIndex));}
 let callout=null;
 spec.levels.forEach((n,i)=>{
  const b=document.createElement('button');b.type='button';b.setAttribute('aria-label',STR.cycleAria(root.dataset.quota,100-n));
  const bar=document.createElement('i');bar.style.setProperty('--cycle-level',n+'%');b.append(bar);const label=document.createElement('span');label.className='cycle-percent';label.textContent=100-n;label.style.bottom=Math.max(7,n*.2)+'px';b.append(label);barsRoot.append(b);
  const enter=()=>{draw(i);
   if(!callout){callout=document.createElement('span');callout.className='cycle-callout';root.appendChild(callout);}
   const win=cycleWindow(i);callout.textContent=`${win.start} · ${win.left}%`;
   const r=b.getBoundingClientRect(),pr=root.getBoundingClientRect();
   callout.style.left=Math.min(Math.max(r.left-pr.left+r.width/2,70),pr.width-70)+'px';callout.style.top=r.top-pr.top-2+'px';};
  const leave=()=>{draw();if(callout){callout.remove();callout=null;}};
  b.addEventListener('mouseenter',enter);b.addEventListener('focus',enter);
  b.addEventListener('mouseleave',leave);b.addEventListener('blur',leave);});
 draw();
});

/* ---- 连接历史：ClashConnectionActivityChart ---- */
function drawConnectionChart(svg,seed){
 svg.replaceChildren();
 const W=svg.viewBox.baseVal.width,H=+svg.viewBox.baseVal.height||78;
 const left=25,top=5,right=2,bottom=17;
 const plotW=W-left-right,plotH=H-top-bottom,maxY=top+plotH;
 const counts=Array.from({length:60},(_,i)=>4+Math.round(3*(1+Math.sin((i+seed)*.22)))+(i%7===0?2:0));
 const maximum=Math.max(...counts);
 const middle=Math.ceil(maximum/2);
 [0,middle,maximum].sort((a,b)=>a-b).forEach(tick=>{
  const y=maxY-plotH*tick/maximum;
  svg.append(svgNode('path',{d:`M${left} ${y}H${W-right}`,stroke:'rgba(0,0,0,.075)','stroke-width':.5,...(tick===0?{}:{'stroke-dasharray':'2 2'})}));
  svg.append(svgNode('text',{x:left-4,y:y+2.5,'text-anchor':'end','font-size':7,fill:SECONDARY},String(tick)));});
 const step=plotW/60,barWidth=Math.max(1,step-Math.min(1.5,step*.28)),unitHeight=plotH/maximum;
 counts.forEach((count,i)=>{
  const x=left+i*step+(step-barWidth)/2;
  const ages=Array.from({length:count},(_,j)=>j===0?1200+j*640+((i*13)%900):60+j*40+((i*7)%60)).sort((a,b)=>b-a);
  ages.forEach((age,unitIndex)=>{
   const gap=Math.min(.6,unitHeight*.16);
   const h=Math.max(.5,unitHeight-gap),y=maxY-(unitIndex+1)*unitHeight+gap/2;
   svg.append(svgNode('rect',{x,y,width:barWidth,height:h,rx:Math.min(1.2,h/3),fill:ageColor(age)}));});});
 [['−60m',left,'start'],['−30m',left+plotW/2,'middle'],['now',W-right,'end']].forEach(([label,x,anchor])=>
  svg.append(svgNode('text',{x,y:H-3,'text-anchor':anchor,'font-size':7,fill:SECONDARY},label)));
}
document.querySelectorAll('.connection-activity').forEach((svg,i)=>drawConnectionChart(svg,i*9));
const connectionMap=document.querySelector('#connection-map');
if(connectionMap)drawConnectionChart(connectionMap,4);
document.querySelectorAll('.conn-icon[data-age]').forEach(icon=>{
 const color=ageColor(+icon.dataset.age);
 icon.style.background=color+'29';icon.style.color=color;});
const rowAges=[130,286];
document.querySelectorAll('.connection-row').forEach((row,i)=>{
 const duration=row.querySelector('.conn-side strong');
 if(duration)duration.style.color=ageColor(rowAges[i%rowAges.length]);});

/* ---- 设置 → 显示：ModelDisplaySettings ---- */
const modelRows=[...document.querySelectorAll('[data-model]')],account=document.querySelector('#demo-account');
function renderSettings(){if(!modelRows.length)return;const selected=modelRows.filter(r=>r.querySelector('[data-mobile]').checked).length;let visible=0;modelRows.forEach(row=>{const menu=row.querySelector('[data-menu]'),mobile=row.querySelector('[data-mobile]');menu.disabled=!account.checked;mobile.disabled=mobile.checked?selected<=1:selected>=2;mobile.title=mobile.disabled?(mobile.checked?STR.atLeastOne:STR.deselectFirst):STR.controlsMobile;if(account.checked&&menu.checked)visible++;});document.querySelector('#menu-count').textContent=STR.menuCount(visible,modelRows.length);document.querySelector('#mobile-count').textContent=STR.mobileCount(selected);document.querySelector('#show-all').disabled=account.checked&&modelRows.every(r=>r.querySelector('[data-menu]').checked);document.querySelector('#selection-help').textContent=STR.help;}
document.querySelectorAll('.settings-table input,.settings-table select').forEach(c=>c.addEventListener('change',renderSettings));
if(document.querySelector('#show-all'))document.querySelector('#show-all').addEventListener('click',()=>{account.checked=true;modelRows.forEach(r=>r.querySelector('[data-menu]').checked=true);renderSettings();});
renderSettings();

window.addEventListener('message',event=>{document.querySelectorAll('iframe').forEach(frame=>{if(event.source===frame.contentWindow&&event.data?.type==='aqb-preview-ready')frame.dataset.ready='true';});});
