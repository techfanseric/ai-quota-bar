// /admin「账号额度详情」：层级与文案沿用 macOS 左键菜单（AIQuotaBar/Views/MenuView.swift），
// 排版是后台自己的「模型列」—— 供应商 → 账号 → 模型列，同一账号下每个模型并排一列。
// 列内仍是 App 的行头、胶囊条／面积曲线、元信息行与跨周期柱图；文案、排序、配色阈值
// 与折叠规则都对齐 ModelUsageData / AppLanguage / UsagePace。数据由 admin.js 传入，
// 图表交给 admin-charts.js。CSP-safe：无 innerHTML、无内联事件、无 <style> 注入。
window.AdminQuota=(()=>{
const $=id=>document.getElementById(id);
const ZH=document.documentElement.lang.indexOf('zh')===0;
const HOUR=3600000,DAY=86400000;
// App: effectiveWarningThreshold 未开启告警时固定 20。
const WARNING=20;
// App: cloudCurrentWindowVisibilityLimit 默认 1 小时 —— 超过这个时间的账号行只保留快照表达。
const FRESH=HOUR;
const numberFormat=new Intl.NumberFormat(ZH?'zh-CN':'en-US');
const clamp=(v,lo,hi)=>Math.min(hi,Math.max(lo,v));
const p2=n=>String(n).padStart(2,'0');
const parseTime=value=>{const t=Date.parse(value||'');return Number.isFinite(t)?t:null;};
// 展示时区：中文界面按 UTC+8 读小时／日界线，英文界面保持 UTC。
// 数据本身仍是 UTC，这里只影响显示与"天"的切分，表头会标出时区。
const tzOffset=()=>document.documentElement.lang.indexOf('zh')===0?480:0;
const localDate=t=>new Date(t+tzOffset()*60000);
const md=t=>{const d=localDate(t);return p2(d.getUTCMonth()+1)+'/'+p2(d.getUTCDate());};
const hm=t=>{const d=localDate(t);return p2(d.getUTCHours())+':'+p2(d.getUTCMinutes());};
const mh=t=>md(t)+' '+hm(t);
const hourStart=t=>Math.floor((t+tzOffset()*60000)/HOUR)*HOUR-tzOffset()*60000;
const nextMidnight=t=>Math.floor((t+tzOffset()*60000)/DAY)*DAY+DAY-tzOffset()*60000;
const T={
 noData:ZH?'暂无数据':'No data',
 // MenuView 里未命名账号就是英文占位，这里保持一致。
 unknownAccount:'Unknown account',
 minLeft:v=>ZH?`最低剩余 ${Math.round(v)}%`:`lowest left ${Math.round(v)}%`,
 modelsCount:n=>ZH?`${n} 个模型`:`${n} model${n===1?'':'s'}`,
 weekly:ZH?'周':'Weekly',
 weeklyFull:ZH?'周未用':'Weekly unused',
 cycleShort:ZH?'5 小时周期':'5h cycles',
 cycleLong:ZH?'周周期':'Week cycles',
 cycleMonthly:ZH?'月度周期':'Monthly cycles',
 loading:ZH?'历史加载中…':'Loading history…',
 historyFailed:ZH?'历史加载失败，请重试。':'History failed — retry.',
 noHistory:ZH?'近 7 天没有上报样本。':'No samples in the last 7 days.',
 exhausted:(n,open)=>open
  ?(ZH?`收起 ${n} 个已用完模型`:`Hide ${n} exhausted models`)
  :(ZH?`展开 ${n} 个已用完模型`:`Show ${n} exhausted models`),
 unused:(n,open)=>open
  ?(ZH?`收起 ${n} 个满额度未使用模型`:`Hide ${n} unused full-quota models`)
  :(ZH?`展开 ${n} 个满额度未使用模型`:`Show ${n} unused full-quota models`),
 allUnused:ZH?'该账号的模型都还没使用，额度都是满的。':'All tracked models are still at full quota.',
 adminExtra:ZH?'后台补充 · 每小时消耗':'Admin extra · hourly consumption',
 adminExtraHint:ZH?'后台分析用的每小时消耗，App 菜单里没有这一层':'per-hour consumption is an admin-only layer, not part of the app menu',
 timezone:ZH?'UTC+8':'UTC',
};

// ModelUsageData.parsedDetail：detail_text 以 " · " 分段，plan / source / rest。
const looksLikePlan=part=>{const lower=part.toLowerCase();
 return lower==='pro'||lower==='plus'||lower==='team'||lower==='enterprise'
  ||lower.startsWith('pro ')||lower.startsWith('pro_')||lower.startsWith('pro-');};
const parseDetail=item=>{
 const detail=(item&&item.detail_text)||'';
 const result={plan:null,source:null,rest:null};
 if(!detail)return result;
 const rest=[];
 for(const part of String(detail).split(' · ')){
  if(!part)continue;
  if(looksLikePlan(part)&&!result.plan)result.plan=part;
  else if(!result.source)result.source=part;
  else rest.push(part);
 }
 result.rest=rest.length?rest.join(' · '):null;
 return result;
};
// ModelRow.tint：阈值与 App 一致（已用 ≥100 红、≥80 橙、剩余低于告警线橙、有消耗绿、未消耗灰）。
const tintFor=(used,left)=>{
 if(used==null||left==null)return '#8a948d';
 if(used>=100)return '#9b4a32';
 if(used>=80)return '#b07a2a';
 if(used>0&&left<=WARNING)return '#b07a2a';
 if(used>0)return '#507a59';
 return '#8a948d';
};
// UsagePace.stage：|delta| ≤2 onTrack、≤6 slightly、≤12 ahead/behind、其余 far。
const paceStage=delta=>{const abs=Math.abs(delta);
 if(abs<=2)return 'onTrack';
 if(abs<=6)return delta>=0?'slightlyAhead':'slightlyBehind';
 if(abs<=12)return delta>=0?'ahead':'behind';
 return delta>=0?'farAhead':'farBehind';};
// UsagePace.Stage.isAhead：onTrack/behind 系列 = 省（绿），ahead 系列 = 超额（红）。
const paceAhead=stage=>stage==='onTrack'||stage.endsWith('Behind');
// AppLanguage.paceLabel
const paceLabel=(stage,delta)=>{
 const value=Math.round(Math.abs(delta));
 if(stage==='onTrack')return value>0
  ?(delta>0?(ZH?`超额 ${value}%`:`${value}% in deficit`):(ZH?`余量 ${value}%`:`${value}% in reserve`))
  :(ZH?'节奏正常':'On pace');
 return stage.endsWith('Ahead')
  ?(ZH?`超额 ${value}%`:`${value}% in deficit`)
  :(ZH?`余量 ${value}%`:`${value}% in reserve`);
};
// ModelUsageData.currentIntervalRemainingText
const remainingText=item=>{
 const percent=Number(item.current_interval_remaining_percent);
 if(Number.isFinite(percent))return `${percent}%`;
 return `${Number(item.current_interval_remaining)||0}${item.value_suffix||''}`;
};
// ModelRow.metadataRow 的周额度表达（周未用 / 周 x% / 周 x/y）。
const weeklyText=item=>{
 const percent=Number(item.weekly_remaining_percent);
 const total=Number(item.weekly_total)||0,remaining=Number(item.weekly_remaining)||0;
 if(!Number.isFinite(percent)&&!(total>0))return null;
 if(total-remaining<=0)return T.weeklyFull;
 if(!(total>0)&&Number.isFinite(percent))return `${T.weekly} ${percent}%`;
 return `${T.weekly} ${numberFormat.format(remaining)}/${numberFormat.format(total)}`;
};
// ModelUsageData.resetTimeText：不足 24 小时的窗口显示整段，长窗口只显示重置时刻。
const resetsText=(start,end,duration)=>{
 if(start==null||end==null)return null;
 if(duration!=null&&duration<DAY)return `${md(start)} ${hm(start)}-${hm(end)}`;
 return `${md(end)} ${hm(end)}`;
};
// ModelUsageData.quotaChartWindow：显式窗口优先，其次 GLM 5h 滚动窗口、Kimi 月度窗口。
const chartWindow=(item,start,end,duration,now)=>{
 if(start!=null&&end!=null&&end>start)return {start,end,duration};
 if(item.provider==='glm'&&/5h/i.test(item.model_name||item.model_id||''))
  return {start:now-5*HOUR,end:now,duration:5*HOUR};
 if(item.provider==='kimi'&&(item.model_name||'')==='Total usage'&&end!=null){
  const month=new Date(end);month.setUTCMonth(month.getUTCMonth()-1);
  const derived=month.getTime();
  return {start:derived,end,duration:end-derived};
 }
 return null;
};
// ModelsRows.isOrderedBeforeInMenu：5h → Weekly → Spark → 短周期 → 长周期，再按重置时间与名称。
const modelPriority=model=>{
 const name=(model.name||'').toLowerCase();
 if(name==='5h')return 0;
 if(name==='weekly')return 1;
 if(name.includes('spark')&&model.isShort)return 2;
 if(name.includes('spark')&&name.includes('weekly'))return 3;
 return model.isShort?4:5;
};
const orderModels=(lhs,rhs)=>{
 const lp=modelPriority(lhs),rp=modelPriority(rhs);
 if(lp!==rp)return lp-rp;
 const le=lhs.windowEnd==null?Infinity:lhs.windowEnd,re=rhs.windowEnd==null?Infinity:rhs.windowEnd;
 if(le!==re)return le-re;
 return lhs.name.localeCompare(rhs.name);
};

function deriveModel(item,now){
 const total=Number(item.current_interval_total)||0;
 const remaining=Number(item.current_interval_remaining)||0;
 const percent=Number(item.current_interval_remaining_percent);
 const hasPercent=Number.isFinite(percent);
 const left=hasPercent?percent:(total>0?remaining/total*100:null);
 const used=left==null?null:clamp(100-left,0,100);
 const start=parseTime(item.reset_start_time),end=parseTime(item.reset_end_time);
 const hasWindow=start!=null&&end!=null&&end>start;
 const duration=hasWindow?end-start:null;
 const detail=parseDetail(item);
 const window=chartWindow(item,start,end,duration,now);
 const isShort=duration!=null?duration<DAY:false;
 const model={item,name:item.model_name||item.model_id||item.model_id,left,used,remainingText:remainingText(item),
  weeklyText:weeklyText(item),windowStart:start,windowEnd:end,duration,window,isShort,
  isCurrentWindow:hasWindow?start<=now&&now<=end:!hasWindow,
  source:detail.source||'Cloud',plan:detail.plan,rest:detail.rest,
  sampledAt:parseTime(item.sampled_at),tint:tintFor(used,left)};
 model.resetText=resetsText(start,end,duration);
 model.cycleLabel=model.isShort?T.cycleShort:(item.provider==='kimi'&&model.name==='Total usage'?T.cycleMonthly:T.cycleLong);
 model.exhausted=left!=null&&left<=0;
 model.unused=left!=null&&left>=100;
 // currentIntervalPace：匀速预期 vs 实际已用；刚开始且已有消耗不计算。
 let pace=null;
 if(hasWindow&&used!=null){
  const elapsed=clamp(now-start,0,duration);
  if(!(elapsed===0&&used>0)){
   const expected=clamp(elapsed/duration*100,0,100);
   const delta=used-expected,stage=paceStage(delta);
   pace={expected,actual:used,delta,stage,ahead:paceAhead(stage),label:paceLabel(stage,delta)};
  }
 }
 model.pace=pace;
 // ModelRow.paceForLabel：短周期只在偏离时显示，长周期常驻。
 model.showPace=pace!=null&&(!model.isShort||pace.stage!=='onTrack');
 return model;
}

const state={items:[],teamId:'',view:'cards',search:'',open:new Set(),collapsed:new Set(),
 showExhausted:new Set(),showUnused:new Set(),showHourly:new Set(),history:new Map(),accounts:[],touched:false,
 rendering:false,pending:false};

function buildAccounts(){
 const team=state.teamId;
 const search=state.search.trim().toLowerCase();
 const accounts=new Map();
 for(const item of state.items){
  if(team&&item.team_id!==team)continue;
  const key=item.team_id+'|'+item.provider+'|'+(item.account_name??'');
  if(!accounts.has(key))accounts.set(key,{key,team_id:item.team_id,team_name:item.team_name||item.team_id,
   provider:item.provider,account_name:item.account_name,models:[]});
  accounts.get(key).models.push(item);
 }
 const now=Date.now();
 state.accounts=[...accounts.values()].map(account=>{
  const models=account.models.map(item=>deriveModel(item,now));
  const lefts=models.map(model=>model.left).filter(value=>value!=null);
  const worst=lefts.length?Math.min(...lefts):null;
  const latest=account.models.reduce((max,item)=>(item.sampled_at||'')>max?item.sampled_at||'':max,'');
  const plans=models.map(model=>model.plan).filter(Boolean);
  const sources=models.map(model=>model.source);
  return {...account,rows:models.sort(orderModels),worst,latest:parseTime(latest||''),
   stale:!(now-(parseTime(latest||'')||0)<=FRESH),
   plan:plans.length?plans[0]:null,source:sources.length?sources[0]:'Cloud',
   active:models.some(model=>model.isCurrentWindow)||now-(parseTime(latest||'')||0)<=FRESH};
 });
 if(search)state.accounts=state.accounts.filter(account=>matches(account,search));
 // 账号排序：先最低剩余，再最新上报。供应商排序：先该供应商最低剩余。
 state.accounts.sort((a,b)=>(a.worst??101)-(b.worst??101)
  ||((b.latest??0)-(a.latest??0))||a.key.localeCompare(b.key));
 return state.accounts;
}
const matches=(account,search)=>[account.account_name,account.team_name,account.provider,
 ...account.rows.map(row=>row.name)].filter(Boolean).join(' ').toLowerCase().includes(search);

function isOpen(account){
 return state.open.has(account.key)||(state.search.trim()&&matches(account,state.search.trim().toLowerCase()));
}
// 默认展开最紧张的一个账号，其余折叠 —— App 是「当前账号展开、其余收起」，
// 后台没有"当前账号"，最紧张的账号就是最该被看见的那个。
function applyDefault(accounts){
 if(state.touched||!accounts.length)return;
 const worst=accounts.filter(a=>a.worst!=null).sort((a,b)=>a.worst-b.worst)[0]||accounts[0];
 state.open=new Set([worst.key]);
}
function pruneOpen(accounts){
 const keys=new Set(accounts.map(account=>account.key));
 for(const key of [...state.open])if(!keys.has(key))state.open.delete(key);
 for(const key of [...state.collapsed])if(!keys.has(key))state.collapsed.delete(key);
}

async function loadHistory(account){
 const entry={status:'loading',samples:[]};
 state.history.set(account.key,entry);
 try{
  const response=await fetch('/v1/admin/data/quota-history?'+new URLSearchParams(
   {team_id:account.team_id,provider:account.provider,account:account.account_name||'',hours:'168'}),
   {credentials:'same-origin'});
  const data=await response.json();
  if(!response.ok)throw new Error(data.error||'request_failed');
  if(state.history.get(account.key)!==entry)return;
  entry.status='ready';entry.samples=Array.isArray(data.samples)?data.samples:[];
 }catch{
  if(state.history.get(account.key)!==entry)return;
  entry.status='error';
 }
 renderCards();
}
// 跨周期 utilization 柱：按 reset_end_time ±120s 合并取峰值，剔除进行中周期，
// 短周期最多 30 根、长周期 12 根（ModelUtilizationHistory / MenuView 同一语义）。
function cyclesFor(samples,duration){
 const now=Date.now(),buckets=[];
 for(const sample of samples){
  const resetsAt=parseTime(sample.reset_end_time);
  if(resetsAt==null)continue;
  const used=deriveModel(sample,now).used;
  if(used==null||used<=0)continue;
  const bucket=buckets.find(item=>Math.abs(item.resetsAt-resetsAt)<=120000);
  if(bucket){bucket.resetsAt=Math.max(bucket.resetsAt,resetsAt);bucket.peakPercent=Math.max(bucket.peakPercent,used);}
  else buckets.push({resetsAt,peakPercent:used});
 }
 return buckets.filter(bucket=>bucket.resetsAt<=now).sort((a,b)=>a.resetsAt-b.resetsAt)
  .slice(duration!=null&&duration<DAY?-30:-12);
}
// 每 UTC 小时的消耗降幅（后台补充，App 菜单里没有这一层）。
function hourlyFor(samples){
 const buckets=[],byHour=new Map();let previous=null;
 for(const sample of samples){
  const time=parseTime(sample.sampled_at);
  if(time==null)continue;
  const left=deriveModel(sample,time).left;
  if(left==null)continue;
  const bucketStart=hourStart(time);
  let bucket=byHour.get(bucketStart);
  if(!bucket){bucket={hourStart:bucketStart,consumedPercent:0};byHour.set(bucketStart,bucket);buckets.push(bucket);}
  if(previous!=null)bucket.consumedPercent+=Math.max(0,previous-left);
  previous=left;
 }
 return buckets.slice(-48);
}

function el(tag,className,text){
 const node=document.createElement(tag);
 if(className)node.className=className;
 if(text!=null)node.textContent=text;
 return node;
}
const charts=()=>window.AdminQuotaCharts;
const SVG_NS='http://www.w3.org/2000/svg';
// App 用 SF Symbol chevron.down / chevron.right（8pt bold、tertiary）。
// 网页端用同尺寸的内联 svg 描边，8px 文字三角在 1200px 版面里几乎不可见。
const chevron=open=>{
 const node=document.createElementNS(SVG_NS,'svg');
 node.setAttribute('viewBox','0 0 10 10');
 node.setAttribute('width','10');node.setAttribute('height','10');
 node.setAttribute('aria-hidden','true');
 node.setAttribute('data-open',open?'true':'false');
 const path=document.createElementNS(SVG_NS,'path');
 path.setAttribute('d',open?'M2.6 4.2 5 6.6 7.4 4.2':'M4.2 2.6 6.6 5 4.2 7.4');
 for(const [key,value] of Object.entries({fill:'none',stroke:'currentColor','stroke-width':1.5,
  'stroke-linecap':'round','stroke-linejoin':'round'}))path.setAttribute(key,value);
 node.append(path);
 return node;
};
// ProviderLogo.assetName：codex / glm(zai) 是白色单色版，网页端反相成墨色；
// kimi / minimax 保持品牌色。
const LOGO={codex:{file:'codex.svg',mono:true},glm:{file:'zai.svg',mono:true},
 kimi:{file:'kimi.svg',mono:false},minimax:{file:'minimax.svg',mono:false}};

function capsuleBar(model){
 // ModelRow 的胶囊条兜底：6pt 胶囊按已用比例填充，长窗口补天分隔线，
 // 节奏偏离时画 PaceTipStripes 的双段标记。
 const wrap=el('div','qm-capsule');
 const bar=el('div','qm-capsule-track');
 const fill=el('div','qm-capsule-fill');
 fill.style.width=(model.used==null?0:model.used)+'%';
 fill.style.background=model.tint;
 bar.append(fill);
 const window=model.window;
 if(window&&!model.isShort){
  const start=window.start,duration=Math.max(window.duration||0,1);
  for(let tick=nextMidnight(start);tick<window.end;tick+=DAY){
   const marker=el('div','qm-capsule-marker');
   marker.style.left=((tick-start)/duration*100)+'%';
   marker.setAttribute('title',md(tick));
   bar.append(marker);
  }
 }
 if(model.pace&&model.pace.stage!=='onTrack'&&window){
  const pace=el('div','qm-capsule-pace');
  pace.style.left=(window.duration>0?model.pace.expected:0)+'%';
  pace.style.color=model.pace.ahead?'#507a59':'#9b4a32';
  bar.append(pace);
 }
 wrap.append(bar);
 if(model.window)wrap.setAttribute('title',`${mh(model.window.start)} → ${mh(model.window.end)}`);
 return wrap;
}

// 两段式渲染的第一段：只搭结构（列头 + 空的绘图区），把画图所需的数据挂在 box 上。
// 图表一律不在这里画 —— curve()/cycleBars()/hourlyBars() 都靠 container.clientWidth
// 定尺寸（viewBox 与像素 1:1），而此刻 box 还挂在游离的树上，clientWidth 恒为 0。
// 见 paintModel 的说明。
function modelRow(model,account,history){
 const box=el('div','qm-model');
 const head=el('div','qm-model-head');
 const name=el('span','qm-model-name',model.name);
 // 列只有 ~180px 宽，模型名必然省略；把全文挂在 title 上，别让运维猜。
 name.setAttribute('title',model.name);
 const right=el('strong','qm-model-right',model.remainingText);
 right.style.color=model.tint;
 head.append(name,right);
 const plot=el('div','qm-plot');
 box.append(head,plot);
 box._quota={model,history,plot};
 return box;
}

// 第二段：box 已经进了文档，clientWidth 量得到真实列宽，这时画图才不会返工。
function paintModel(box){
 const spec=box._quota;
 if(!spec)return;
 box._quota=null;
 const {model,history,plot}=spec;
 const ready=history.status==='ready';
 const samples=ready?history.samples.filter(sample=>sample.model_id===model.item.model_id):[];
 const inWindow=model.window
  ?samples.filter(sample=>{const t=parseTime(sample.sampled_at);
   return t!=null&&t>=model.window.start&&t<=model.window.end;})
  :[];
 // 曲线只在窗口仍在进行、且窗口内有样本时画；过期窗口退回胶囊条快照表达。
 const useCurve=ready&&inWindow.length>0&&model.window&&model.isCurrentWindow;
 if(useCurve&&charts()){
  charts().curve(plot,{points:inWindow.map(sample=>({t:parseTime(sample.sampled_at),y:deriveModel(sample,Date.now()).left})),
   windowStart:model.window.start,windowEnd:model.window.end,
   yMax:Number(model.item.current_interval_total)>0?Number(model.item.current_interval_total):100,
   tint:model.tint,warningThreshold:WARNING,
   pace:model.pace&&(!model.isShort||model.pace.stage!=='onTrack')?{ahead:model.pace.ahead}:null,
   aria:`${model.name} ${model.remainingText}`,tipValue:v=>`${Math.round(v)}${model.item.value_suffix||''}`});
 }else plot.append(capsuleBar(model));
 // 元信息行：左侧是跨周期标签，右侧是周额度 · 节奏 · 重置（App metadataRow）。
 const meta=el('div','qm-meta');
 const cycles=ready?cyclesFor(samples,model.duration):[];
 const left=el('span','qm-meta-left',cycles.length?`${model.cycleLabel} · left`:'');
 const rightMeta=el('span','qm-meta-right');
 const pieces=[];
 if(model.weeklyText)pieces.push(model.weeklyText);
 if(model.showPace&&model.pace){
  const pace=el('span','qm-pace',model.pace.label);
  if(model.pace.stage.endsWith('Ahead'))pace.style.color='#9b4a32';
  pieces.push(pace);
 }
 if(model.resetText)pieces.push(model.resetText);
 pieces.forEach((piece,index)=>{
  if(index)rightMeta.append(el('span','qm-dot','·'));
  rightMeta.append(typeof piece==='string'?el('span',null,piece):piece);
 });
 if(!left.textContent&&!rightMeta.children.length)meta.style.display='none';
 meta.append(left,rightMeta);
 box.append(meta);
 // App 的柱图同时收已完成周期和当前进行中的周期（ModelUtilizationBarsView 的
 // currentCycle 参数），后台没有"当前周期"的概念，这里用 head 快照的窗口补上。
 const bars=model.window&&model.isCurrentWindow&&model.used!=null
  ?[...cycles,{resetsAt:model.window.end,peakPercent:model.used,current:true}].sort((a,b)=>a.resetsAt-b.resetsAt)
  :cycles;
 if(bars.length){
  const cycleBox=el('div','qm-cycles');
  charts().cycleBars(cycleBox,{cycles:bars,tint:model.tint,cycleDuration:model.duration});
  box.append(cycleBox);
 }
 if(ready&&samples.length){
  const hourly=hourlyFor(samples);
  if(hourly.length>1){
   // 每小时消耗是后台自带的补充层，App 菜单里没有，默认收起。
   const key=model.item.model_id;
   const open=state.showHourly.has(key);
   const extra=el('div','qm-extra');
   const toggle=el('button','qm-toggle',T.adminExtra+(open?' ▾':' ▸'));
   toggle.type='button';
   toggle.setAttribute('aria-expanded',open?'true':'false');
   extra.append(toggle);
   if(open){
    const hourlyBox=el('div','qm-chart');
    charts().hourlyBars(hourlyBox,{buckets:hourly});
    extra.append(hourlyBox);
   }else extra.setAttribute('title',T.adminExtraHint);
   toggle.addEventListener('click',()=>{
    if(state.showHourly.has(key))state.showHourly.delete(key);else state.showHourly.add(key);
    renderCards();
   });
   box.append(extra);
  }
 }
 if(!ready){
  box.append(el('div','qm-state',history.status==='error'?T.historyFailed:history.status==='loading'?T.loading:T.noHistory));
 }
}
// 把一棵已入文档的子树里所有待画的模型列画完。
function paintModels(root){
 for(const box of root.querySelectorAll('.qm-model'))paintModel(box);
}

function modelRows(models,account,history){
 const visible=models.filter(model=>!model.exhausted&&!model.unused);
 const exhausted=models.filter(model=>model.exhausted);
 const unused=models.filter(model=>model.unused&&!model.exhausted);
 if(!visible.length&&!exhausted.length&&!unused.length)
  return [el('p','qm-note',T.noData)];
 // 「已用完／未使用」的分组开关必须待在网格外面：一旦它 grid-column:1/-1 跨满
 // 所有轨道，auto-fit 就认为没有空轨道可塌，列宽被钉死在 184px 上下，
 // 整块版面退化成 App 菜单那么宽的一排小卡片。
 const wrap=el('div','qm-models-wrap');
 const grid=el('div','qm-models');
 for(const model of visible)grid.append(modelRow(model,account,history));
 wrap.append(grid);
 for(const [group,set,label] of [[exhausted,state.showExhausted,T.exhausted],[unused,state.showUnused,T.unused]]){
  if(!group.length)continue;
  const open=set.has(account.key);
  const toggle=el('button','qm-toggle',label(group.length,open));
  toggle.type='button';
  toggle.setAttribute('aria-expanded',open?'true':'false');
  toggle.addEventListener('click',()=>{
   if(open)set.delete(account.key);else set.add(account.key);
   state.touched=true;renderCards();
  });
  wrap.append(toggle);
  if(open){
   const revealed=el('div','qm-models');
   for(const model of group)revealed.append(modelRow(model,account,history));
   wrap.append(revealed);
  }
 }
 return [wrap];
}

function accountRow(account,now){
 const open=isOpen(account),row=el('div','qm-account'+(open?' is-open':''));
 const head=el('button','qm-account-head');
 head.type='button';
 head.setAttribute('aria-expanded',open?'true':'false');
 const nameWrap=el('span','qm-account-name');
 nameWrap.append(el('span',null,account.account_name||T.unknownAccount));
 if(account.plan)nameWrap.append(el('em','qm-plan','· '+account.plan));
 const accountChevron=chevron(open);
 accountChevron.setAttribute('class','qm-chev');
 head.append(accountChevron,nameWrap);
 if(state.teamId===''&&account.team_name)head.append(el('span','qm-team',account.team_name));
 // 收起态把来源 · 时间 · 最低剩余放在一行右侧：不展开也能横向比较。
 const meta=el('span','qm-account-meta');
 const stale=account.stale&&account.latest!=null;
 const source=el('span','qm-source'+(stale?' is-stale':''),account.source+' · '+(account.latest!=null?hm(account.latest):'—'));
 meta.append(source);
 if(!open&&account.worst!=null){
  const worst=el('span','qm-worst',T.minLeft(account.worst));
  worst.style.color=tintFor(100-account.worst,account.worst);
  meta.append(el('span','qm-dot','·'),worst);
 }
 head.append(meta);
 head.addEventListener('click',()=>{
  if(state.open.has(account.key))state.open.delete(account.key);else state.open.add(account.key);
  state.touched=true;
  if(isOpen(account)&&!state.history.has(account.key))loadHistory(account);
  renderCards();
 });
 row.append(head);
 return {row,open};
}
// 模型列必须等 row 进了文档之后再填。curve() 是靠 container.clientWidth 定尺寸的
// （viewBox 与像素 1:1），脱离文档时它恒为 0，只能退回 296px 兜底宽度：
// 先按 296 画一张，插入后被 CSS 的 width:100% 拉宽，等高被 viewBox 比例撑大，
// 120ms 后 ResizeObserver 按真实宽度重画又缩回去 —— 账号卡片在两帧之间上下跳一下，
// 看起来就是「每次展开收起都在抖」。
function accountBody(row,account){
 let history=state.history.get(account.key);
 if(!history){history={status:'loading',samples:[]};state.history.set(account.key,history);loadHistory(account);}
 const visibleRows=account.rows.filter(model=>!model.exhausted&&!model.unused);
 row.append(...modelRows(account.rows,account,history));
 if(!account.rows.length)row.append(el('p','qm-note',T.noData));
 else if(!visibleRows.length&&account.rows.every(model=>model.unused))
  row.append(el('p','qm-note',T.allUnused));
 // 结构已全部挂进文档，这时再画图，clientWidth 才是真实列宽。
 paintModels(row);
}

function providerRow(accounts,provider){
 const collapsed=state.collapsed.has(provider);
 const section=el('section','qm-provider'+(collapsed?' is-collapsed':''));
 const head=el('button','qm-provider-head');
 head.type='button';
 head.setAttribute('aria-expanded',collapsed?'false':'true');
 const providerChevron=chevron(!collapsed);
 providerChevron.setAttribute('class','qm-chev');
 head.append(providerChevron);
 // 品牌图标沿用 App 的资源命名（ProviderLogo.assetName）；找不到时保留 12pt 空位，
 // 与 App 用 Color.clear 占位的行为一致，不让标题左右跳动。
 const logo=document.createElement('img');
 logo.className='qm-logo'+(LOGO[provider]&&LOGO[provider].mono?' is-mono':'');
 logo.alt='';
 if(LOGO[provider])logo.src='/provider-logos/'+LOGO[provider].file;
 else logo.style.visibility='hidden';
 logo.addEventListener('error',()=>{logo.style.visibility='hidden';});
 head.append(logo,el('strong','qm-provider-name',provider));
 // App providerHeaderSubtitle：右侧是「活跃账号/总账号」。
 head.append(el('span','qm-provider-count',`${accounts.filter(account=>account.active).length}/${accounts.length}`));
 head.addEventListener('click',()=>{
  if(state.collapsed.has(provider))state.collapsed.delete(provider);else state.collapsed.add(provider);
  state.touched=true;renderCards();
 });
 section.append(head);
 const body=el('div','qm-accounts');
 section.append(body);
 return {section,body,collapsed};
}

function renderCards(){
 const grid=$('quota-cards');
 if(!grid)return;
 // 历史回调可能在渲染过程中再次触发渲染（同步失败、点击回读等），
 // 这里合并成一次后续渲染，避免 DOM 出现半渲染状态。
 if(state.rendering){state.pending=true;return;}
 state.rendering=true;
 try{renderCardsInto(grid);}finally{
  state.rendering=false;
  if(state.pending){state.pending=false;renderCards();}
 }
}
function renderCardsInto(grid){
 grid.replaceChildren();
 const accounts=buildAccounts();
 pruneOpen(accounts);
 applyDefault(accounts);
 if(!accounts.length){grid.append(el('p','empty',T.noData));return;}
 const providers=new Map();
 for(const account of accounts){
  if(!providers.has(account.provider))providers.set(account.provider,[]);
  providers.get(account.provider).push(account);
 }
 const worstOf=accounts=>Math.min(...accounts.map(account=>account.worst??101));
 const ordered=[...providers.entries()].sort((a,b)=>{
  const delta=worstOf(a[1])-worstOf(b[1]);
  return delta!==0?delta:a[0].localeCompare(b[0]);
 });
 const title=el('div','qm-title');
 title.append(el('strong',null,`${ordered.length} Providers · ${accounts.length} Accounts · ${accounts.reduce((sum,account)=>sum+account.rows.length,0)} Models`));
 grid.append(title);
 // 两段式渲染：先把供应商壳挂进文档，再往里填账号，账号行头挂进文档后再填模型列。
 // 图表要靠 clientWidth 定尺寸，脱离文档时量不到（见 accountBody 的注释）。
 for(const [provider,group] of ordered){
  const shell=providerRow(group,provider);
  grid.append(shell.section);
  if(shell.collapsed)continue;
  for(const account of group){
   const row=accountRow(account);
   shell.body.append(row.row);
   if(row.open)accountBody(row.row,account);
  }
 }
}

// 列表视图保留：运维要的是可排序、可复制的原始快照字段。
// 百分比优先用 API 直接给的 percent，缺失时按总量回退（与 ModelUsageData 同口径）。
const percentOrRatio=(item,percentKey,totalKey,remainingKey)=>{
 const percent=Number(item[percentKey]);
 if(Number.isFinite(percent))return percent;
 const total=Number(item[totalKey])||0,remaining=Number(item[remainingKey])||0;
 return total>0?Math.round(remaining/total*100):null;
};
function quotaCell(item){
 const percent=percentOrRatio(item,'current_interval_remaining_percent','current_interval_total','current_interval_remaining');
 if(item.value_suffix==='%')return percent==null?'—':`${percent}%`;
 const total=Number(item.current_interval_total)||0,remaining=Number(item.current_interval_remaining)||0;
 if(!(total>0))return '—';
 return `${numberFormat.format(remaining)} / ${numberFormat.format(total)}`;
}
function weeklyCell(item){
 if(item.value_suffix==='%'){
  const percent=percentOrRatio(item,'weekly_remaining_percent','weekly_total','weekly_remaining');
  return percent==null?'—':`${percent}%`;
 }
 const total=Number(item.weekly_total)||0,remaining=Number(item.weekly_remaining)||0;
 if(!(total>0))return '—';
 return `${numberFormat.format(remaining)} / ${numberFormat.format(total)}`;
}
const stamp=value=>{const t=parseTime(value);return t==null?'—':`${md(t)} ${hm(t)}`;};
function renderList(){
 const body=$('quota-detail-rows');
 if(!body)return;
 body.replaceChildren();
 const items=state.items.filter(item=>!state.teamId||item.team_id===state.teamId);
 if(!items.length){const row=document.createElement('tr'),cell=document.createElement('td');cell.colSpan=9;
  cell.textContent=T.noData;row.append(cell);body.append(row);return;}
 for(const item of items){
  const row=document.createElement('tr');
  const values=[item.team_name||item.team_id,item.provider,item.account_name||T.unknownAccount,
   item.model_name||item.model_id,quotaCell(item),weeklyCell(item),
   item.reset_start_time?`${stamp(item.reset_start_time)} ~ ${stamp(item.reset_end_time)}`:'—',
   item.device_id?item.device_id.slice(0,8)+'…':'—',
   stamp(item.sampled_at)];
  for(const value of values){const cell=document.createElement('td');cell.textContent=String(value);row.append(cell);}
  body.append(row);
 }
}

function setView(view){
 state.view=view;
 try{localStorage.setItem('aqb-admin-quota-view',view);}catch{}
 const cards=$('quota-cards'),table=$('quota-table-wrap');
 if(cards)cards.hidden=view!=='cards';
 if(table)table.hidden=view==='cards';
 const cardsTab=$('qd-view-cards'),listTab=$('qd-view-list');
 if(cardsTab)cardsTab.className='qd-tab'+(view==='cards'?' active':'');
 if(listTab)listTab.className='qd-tab'+(view==='cards'?'':' active');
 for(const [id,hidden] of [['qd-expand-all',view!=='cards'],['qd-collapse-all',view!=='cards'],
  ['qd-search-wrap',view!=='cards']]){
  const node=$(id);
  if(node)node.hidden=hidden;
 }
}

function render(){
 setView(state.view);
 renderList();
 renderCards();
}
// 切视图必须重画：列表视图下 #quota-cards 是 display:none，图表在隐藏容器里量不到
// 列宽，只能退回 296px 的兜底值，切回来时就是一张被拉扁的图。
function switchView(view){
 if(state.view===view)return;
 setView(view);
 renderCards();
}

function setItems(items,options={}){
 state.items=Array.isArray(items)?items:[];
 if(options.reset!==false)state.history.clear();
 render();
}
function setTeam(teamId){
 state.teamId=teamId||'';
 render();
}

function bind(){
 const on=(id,event,handler)=>{const node=$(id);if(node)node.addEventListener(event,handler);};
 on('qd-view-cards','click',()=>switchView('cards'));
 on('qd-view-list','click',()=>switchView('list'));
 on('qd-expand-all','click',()=>{buildAccounts();for(const account of state.accounts)state.open.add(account.key);state.touched=true;renderCards();});
 on('qd-collapse-all','click',()=>{state.open.clear();state.touched=true;renderCards();});
 on('qd-search','input',event=>{state.search=event.target.value||'';renderCards();});
 on('qd-reset-view','click',()=>{state.open.clear();state.collapsed.clear();state.showExhausted.clear();
  state.showUnused.clear();state.showHourly.clear();state.touched=false;state.search='';const search=$('qd-search');if(search)search.value='';
  renderCards();});
 try{
  state.view=localStorage.getItem('aqb-admin-quota-view')||'cards';
 }catch{state.view='cards';}
 const search=$('qd-search');
 if(search)search.placeholder=ZH?'账号 / 模型 / 团队':'account / model / team';
}

bind();
return {bind,setItems,setTeam,render,state,deriveModel,cyclesFor,hourlyFor,paceStage,paceLabel};
})();
