const $=id=>document.getElementById(id);
const EN=document.documentElement.lang.indexOf('en')===0;
const L=EN?'en-US':'zh-CN';
const T={
 noData:EN?'No data':'暂无数据',
 web:EN?'Web':'网页', anonymous:EN?'Anonymous':'匿名用户',
 fbCounts:(p,h)=>EN?`Published ${p} · Hidden ${h}`:`公开 ${p} · 已隐藏 ${h}`,
 published:EN?'Published':'公开', hidden:EN?'Hidden':'已隐藏',
 hide:EN?'Hide':'隐藏', restore:EN?'Restore':'恢复', remove:EN?'Delete':'删除',
 confirmDeleteFeedback:EN?'Delete this feedback? This cannot be undone.':'确定删除这条反馈？删除后无法恢复。',
 active:EN?'Active':'活跃', newD:EN?'New':'新增',
 chartAria:n=>EN?`Daily active & new-device trend over the last ${n} days — expand for the daily data`:`近 ${n} 天每日活跃与新增设备趋势，下方可展开每日数据`,
 updated:EN?'Updated ':'更新于 ',
 firstSeen:d=>EN?'First seen: '+d.slice(0,10)+' (UTC)':'最早接入：'+d.slice(0,10)+'（UTC）',
 noAnalytics:EN?'No devices with analytics enabled yet':'尚无设备开启匿名统计',
 loadFailed:EN?'Load failed — showing the previous result. Refresh to retry.':'数据加载失败，当前显示为上一次结果。请稍后刷新。',
 unavailable:EN?'Service unavailable — try again later.':'服务暂不可用，请稍后重试。',
 attemptsRate:EN?'Too many attempts — try again in 15 minutes.':'尝试过于频繁，请 15 分钟后再试。',
 badPassword:EN?'Incorrect admin password.':'管理员密码不正确。',
 loginUnavailable:EN?'Sign-in service unavailable — try again later.':'登录服务暂不可用，请稍后重试。',
 logoutFailed:EN?'Sign-out failed — retry.':'退出失败，请重试。',
 unnamed:EN?'Unnamed':'未命名',
 selectTeam:EN?'Select a team':'选择团队',
 allTeams:EN?'All teams':'全部团队',
 deleteQuotaHistory:EN?'Delete quota history':'删除额度历史',
 confirmDeleteQuota:(t,p,n)=>EN?`Delete team ${t}'s ${p} / ${n} quota history? Other teams are unaffected. Reporting devices will create new snapshots.`:`删除团队 ${t} 的 ${p} / ${n} 额度历史？其他团队不受影响。正在上报的设备会产生新快照。`,
 deleteRetry:EN?'Delete failed — retry.':'删除失败，请重试。',
 sessionExpired:EN?'Session expired — sign in again.':'登录已过期，请重新登录。',
 dataLoadFailed:EN?'Business data failed to load — confirm the team database migration is complete.':'业务数据加载失败，请确认团队数据库迁移已完成。',
 teamAccountsFailed:EN?'Team accounts failed to load.':'团队账号加载失败。',
 openTeam:EN?'Open dashboard':'打开面板',
 openTeamFailed:EN?'Could not open the team dashboard — retry.':'打开团队面板失败，请重试。',
 d1:(r,w)=>EN?`D1 today: ${r} rows read · ${w} rows written`:`D1 今日读取 ${r} 行 · 写入 ${w} 行`,
 d1Unavailable:EN?'D1 monitoring unavailable or not configured.':'D1 监控暂不可用或尚未配置。',
 modelsCount:n=>EN?`${n} model${n===1?'':'s'}`:`${n} 个模型`,
 minLeft:v=>v==null?(EN?'quota values missing':'无数值额度'):(EN?`lowest left ${Math.round(v)}%`:`最低剩余 ${Math.round(v)}%`),
 weekly:EN?'Weekly':'周',
 resets:EN?'Resets':'重置',
 device:EN?'Device':'设备',
 reported:EN?'Reported':'上报',
 recentCycles:EN?'Recent cycles':'近期周期',
 hourlyUse:EN?'Hourly use':'每小时消耗',
 loadingHistory:EN?'Loading history…':'历史加载中…',
 historyFailed:EN?'History failed — retry.':'历史加载失败，请重试。',
 noHistory:EN?'No samples in the last 7 days.':'近 7 天没有上报样本。',
 paceLabel:delta=>{const value=Math.round(Math.abs(delta));return EN?(value<=2?'On pace':delta>2?`${value}% in deficit`:`${value}% in reserve`):(value<=2?'节奏正常':delta>2?`超额 ${value}%`:`余量 ${value}%`);},
};
let loading=false,quotaItems=[];
async function api(path,options={}) {
 const response=await fetch('/v1/admin/'+path,{credentials:'same-origin',...options});
 const data=await response.json();if(!response.ok){const error=new Error(data.error||'request_failed');error.status=response.status;throw error;}return data;
}
function loginView(){ $('loading').hidden=true;$('dashboard').hidden=true;$('logout').hidden=true;$('login').hidden=false;}
function renderTable(id,rows,columns){const body=$(id);body.replaceChildren();if(!rows.length){const row=document.createElement('tr'),cell=document.createElement('td');cell.colSpan=columns.length;cell.textContent=T.noData;row.append(cell);body.append(row);return;}for(const data of rows){const row=document.createElement('tr');for(const column of columns){const cell=document.createElement('td');cell.textContent=String(column(data));row.append(cell);}body.append(row);}}
async function loadFeedback(){try{renderFeedback(await api('feedback?limit=50'));}catch(error){if(error.status===401)return;if(!$('dashboard').hidden)$('feedback-error').hidden=false;}}
function renderFeedback(data){$('feedback-counts').textContent=T.fbCounts(data.counts.published,data.counts.hidden);$('feedback-error').hidden=true;$('feedback-empty').hidden=data.items.length>0;const rows=$('feedback-rows');rows.replaceChildren();for(const item of data.items){const row=document.createElement('tr');const cell=text=>{const node=document.createElement('td');node.textContent=text;return node;};row.append(cell(item.createdAt.slice(0,16).replace('T',' ')),cell(item.source==='app'?'App':T.web),cell(item.nickname||T.anonymous),cell(item.contact||'—'),cell(item.message),cell((item.appVersion?'v'+item.appVersion:'—')+(item.osVersion?' / macOS '+item.osVersion:'')));const status=document.createElement('td'),badge=document.createElement('span');badge.className='status '+item.status;badge.textContent=item.status==='published'?T.published:T.hidden;status.append(badge);row.append(status);const actions=document.createElement('td');const toggle=document.createElement('button');toggle.type='button';toggle.textContent=item.status==='published'?T.hide:T.restore;toggle.addEventListener('click',async()=>{toggle.disabled=true;try{await api('feedback/status',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({id:item.id,status:item.status==='published'?'hidden':'published'})});await loadFeedback();}catch{$('feedback-error').hidden=false;toggle.disabled=false;}});const remove=document.createElement('button');remove.type='button';remove.className='danger';remove.textContent=T.remove;remove.addEventListener('click',async()=>{if(!confirm(T.confirmDeleteFeedback))return;remove.disabled=true;try{await api('feedback?id='+encodeURIComponent(item.id),{method:'DELETE'});await loadFeedback();}catch{$('feedback-error').hidden=false;remove.disabled=false;}});actions.append(toggle,remove);row.append(actions);rows.append(row);}}
function chart(rows){const svg=$('chart');svg.replaceChildren();const ns='http://www.w3.org/2000/svg';const max=Math.max(3,Math.ceil(Math.max(0,...rows.flatMap(r=>[r.active,r.newInstalls]))/3)*3);const element=(tag,attrs,text)=>{const node=document.createElementNS(ns,tag);for(const [k,v] of Object.entries(attrs))node.setAttribute(k,v);if(text!==undefined)node.textContent=text;svg.append(node);return node;};
 for(let i=0;i<4;i++){const y=15+i*65;element('line',{x1:35,x2:990,y1:y,y2:y,stroke:'#d9dfd6','stroke-width':1});element('text',{x:25,y:y+4,'text-anchor':'end',fill:'#69746c','font-size':10},String(Math.round(max*(3-i)/3)));}
 for(const [key,color] of [['active','#507a59'],['newInstalls','#b0bd9c']]){const points=rows.map((r,i)=>[35+i*955/Math.max(1,rows.length-1),210-r[key]/max*195]);element('polyline',{points:points.map(p=>p.join(',')).join(' '),fill:'none',stroke:color,'stroke-width':2.5});rows.forEach((r,i)=>{const node=element('circle',{cx:points[i][0],cy:points[i][1],r:3,fill:color});const title=document.createElementNS(ns,'title');title.textContent=r.day+' · '+(key==='active'?T.active:T.newD)+' '+r[key];node.append(title);});}
 svg.setAttribute('aria-label',T.chartAria(rows.length));$('chart-from').textContent=rows[0]?.day||'';$('chart-to').textContent=rows.at(-1)?.day||'';
}
async function load(){if(loading)return;loading=true;$('refresh').disabled=true;$('error').hidden=true;try{const data=await api('overview?days='+$('days').value);$('login').hidden=true;$('loading').hidden=true;$('dashboard').hidden=false;$('logout').hidden=false;for(const [key,value]of Object.entries(data.metrics))if($(key))$(key).textContent=Number(value).toLocaleString(L);$('updated').textContent=T.updated+data.generatedAt.replace('T',' ').slice(0,19)+' UTC';$('coverage-since').textContent=data.coverageSince?T.firstSeen(data.coverageSince):T.noAnalytics;$('empty').hidden=data.metrics.total>0;chart(data.trend);renderTable('daily-rows',[...data.trend].reverse(),[r=>r.day,r=>r.active,r=>r.newInstalls]);for(const [id,rows,label] of [['version-rows',data.versions,r=>r.version+' ('+r.build+')'],['system-rows',data.systems,r=>'macOS '+r.version]]){const total=data.metrics.reporting_month;renderTable(id,rows,[label,r=>r.installs,r=>total?(r.installs/total*100).toFixed(1)+'%':'—']);}$('legacy-devices').textContent=data.legacy.syncedDevices;$('legacy-members').textContent=data.legacy.configuredMembers;await loadBusinessData();}catch(error){if(error.status===401){loginView();}else if(!$('dashboard').hidden){$('error').hidden=false;$('error').textContent=T.loadFailed;}else{loginView();$('login-error').textContent=T.unavailable;}}finally{loading=false;$('refresh').disabled=false;}}
$('login-form').addEventListener('submit',async event=>{event.preventDefault();const button=event.currentTarget.querySelector('button');button.disabled=true;$('login-error').textContent='';try{await api('login',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({password:$('password').value})});$('password').value='';await load();loadFeedback();}catch(error){$('login-error').textContent=error.status===429?T.attemptsRate:error.status===401?T.badPassword:T.loginUnavailable;}finally{button.disabled=false;}});
$('logout').addEventListener('click',async()=>{try{await api('logout',{method:'POST'});loginView();$('password').value='';}catch{$('error').hidden=false;$('error').textContent=T.logoutFailed;}});
$('days').addEventListener('change',load);$('refresh').addEventListener('click',()=>{load();loadFeedback();});load();loadFeedback();

function renderTeams(rows){
 const body=$('team-rows');body.replaceChildren();
 if(!rows.length){const row=document.createElement('tr'),cell=document.createElement('td');cell.colSpan=6;cell.textContent=T.noData;row.append(cell);body.append(row);return;}
 for(const team of rows){
  const row=document.createElement('tr');
  for(const value of [team.team_name,team.team_id,team.members,team.devices,team.events]){const cell=document.createElement('td');cell.textContent=String(value);row.append(cell);}
  const cell=document.createElement('td'),button=document.createElement('button');
  button.type='button';button.textContent=T.openTeam;
  button.addEventListener('click',async()=>{
   button.disabled=true;
   try{await api('team-session',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({teamID:team.team_id})});window.open('/team','_blank');}
   catch{$('data-error').textContent=T.openTeamFailed;}
   finally{button.disabled=false;}
  });
  cell.append(button);row.append(cell);body.append(row);
 }
}
async function loadBusinessData(){
 try{
  const [teams,legacy,audit,quota]=await Promise.all([api('data/teams'),api('data/legacy/accounts'),api('data/audit'),api('data/quota')]);
  $('data-error').textContent='';
  renderTeams(teams.teams);
  const select=$('data-team'),previous=select.value;select.replaceChildren(new Option(T.allTeams,''));
  for(const team of teams.teams)select.add(new Option(team.team_name,team.team_id));
  if(teams.teams.some(t=>t.team_id===previous))select.value=previous;
  quotaItems=quota.items;qd.history.clear();renderQuotaDetail();renderQuotaCards();
  renderTable('legacy-account-rows',legacy.accounts,[r=>r.provider,r=>r.account_name||T.unnamed,r=>r.model_count,r=>r.sample_count]);
  renderTable('audit-rows',audit.items,[r=>r.created_at,r=>r.team_id,r=>r.actor,r=>r.action,r=>r.target]);
  await loadTeamAccounts();
 }catch(error){$('data-error').textContent=error.status===401?T.sessionExpired:T.dataLoadFailed;}
 try{const d=await api('d1-usage');$('d1-status').textContent=T.d1(Number(d.rowsRead).toLocaleString(L),Number(d.rowsWritten).toLocaleString(L));}catch{$('d1-status').textContent=T.d1Unavailable;}
}
async function loadTeamAccounts(){
 const team=$('data-team').value,rows=$('quota-rows');rows.replaceChildren();if(!team)return;
 try{const data=await api('data/accounts?team_id='+encodeURIComponent(team));if($('data-team').value!==team)return;
  for(const item of data.accounts){const row=document.createElement('tr');for(const text of [item.provider,item.account_name||T.unnamed,item.model_count,item.sample_count,item.latest_sampled_at]){const td=document.createElement('td');td.textContent=text;row.append(td);}
   const td=document.createElement('td'),button=document.createElement('button');button.textContent=T.deleteQuotaHistory;button.type='button';button.addEventListener('click',async()=>{
    if(!confirm(T.confirmDeleteQuota(team,item.provider,item.account_name||T.unnamed)))return;
    button.disabled=true;try{await api('data/accounts?'+new URLSearchParams({team_id:team,provider:item.provider,account_name:item.account_name}),{method:'DELETE'});await loadBusinessData();}catch{$('data-error').textContent=T.deleteRetry;button.disabled=false;}
   });td.append(button);row.append(td);rows.append(row);
  }
  if(!data.accounts.length){const row=document.createElement('tr'),cell=document.createElement('td');cell.colSpan=6;cell.textContent=T.noData;row.append(cell);rows.append(row);}
 }catch{$('data-error').textContent=T.teamAccountsFailed;}
}
const numberFormat=new Intl.NumberFormat(L);
const quotaCell=(remaining,total,suffix)=>{
 if(!(Number(total)>0))return '—';
 if(suffix==='%')return numberFormat.format(remaining)+'%';
 return numberFormat.format(remaining)+' / '+numberFormat.format(total)+(suffix||'');
};
const minute=value=>value?value.replace('T',' ').slice(0,16):'—';
function renderQuotaDetail(){
 const team=$('data-team').value,rows=$('quota-detail-rows');
 const items=quotaItems.filter(item=>!team||item.team_id===team);
 rows.replaceChildren();
 if(!items.length){const row=document.createElement('tr'),cell=document.createElement('td');cell.colSpan=9;cell.textContent=T.noData;row.append(cell);rows.append(row);return;}
 for(const item of items){
  const row=document.createElement('tr');
  for(const text of [item.team_name||item.team_id,item.provider,item.account_name||T.unnamed,item.model_name||item.model_id,
   quotaCell(item.current_interval_remaining,item.current_interval_total,item.value_suffix),
   quotaCell(item.weekly_remaining,item.weekly_total,item.value_suffix),
   item.reset_start_time?minute(item.reset_start_time)+' ~ '+minute(item.reset_end_time):'—',
   item.device_id?item.device_id.slice(0,8)+'…':'—',minute(item.sampled_at)]){
   const cell=document.createElement('td');cell.textContent=String(text);row.append(cell);
  }
  rows.append(row);
 }
}
// 直观视图：还原 App 菜单弹窗的账号行——胶囊条按"已用比例"填充，
// 右侧文字为剩余，阈值配色（≥100% 红、≥80% 或剩余≤20% 橙、有消耗绿、未消耗灰）。
const qd={view:(()=>{try{return localStorage.getItem('aqb-admin-quota-view')||'cards'}catch{return 'cards'}})(),open:new Set(),history:new Map(),accounts:[]};
const qdTint=(used,left)=>{
 if(used>=100)return '#9b4a32';
 if(used>=80||(left<=20&&used>0))return '#b07a2a';
 if(used>0)return '#507a59';
 return '#8a948d';
};
const qdModel=item=>{
 const percent=item.value_suffix==='%';
 const total=Number(item.current_interval_total)||0,remaining=Number(item.current_interval_remaining)||0;
 const left=percent?remaining:(total>0?remaining/total*100:null);
 const used=left==null?null:Math.max(0,Math.min(100,100-left));
 return {item,left,used,right:quotaCell(remaining,total,item.value_suffix)};
};
const dayMinute=value=>value?value.slice(5,16).replace('T',' '):'—';
function qdWeeklyText(item){
 const total=Number(item.weekly_total)||0,remaining=Number(item.weekly_remaining)||0;
 if(item.value_suffix==='%'&&total===100)return `${T.weekly} ${remaining}%`;
 if(total>0)return `${T.weekly} ${numberFormat.format(remaining)} / ${numberFormat.format(total)}`;
 return null;
}
// 每账号懒加载 168h 历史：qd.history 以账号 key 缓存 {status:'loading'|'ready'|'error',samples}，
// 业务数据刷新时整体失效（loadBusinessData 里 clear），展开中的卡片在回调后重渲染。
async function qdLoadHistory(acc){
 const entry={status:'loading',samples:[]};
 qd.history.set(acc.key,entry);
 try{
  const data=await api('data/quota-history?'+new URLSearchParams({team_id:acc.team_id,provider:acc.provider,account:acc.account_name||'',hours:'168'}));
  if(qd.history.get(acc.key)!==entry)return;
  entry.status='ready';entry.samples=Array.isArray(data.samples)?data.samples:[];
 }catch(error){
  if(qd.history.get(acc.key)!==entry)return;
  entry.status='error';
 }
 renderQuotaCards();
}
// 单模型分析（纯函数）：样本升序，item 为该模型的 head 快照。
function qdModelAnalysis(item,samples,now){
 const reference=samples.length?samples[samples.length-1]:item;
 const start=reference.reset_start_time?Date.parse(reference.reset_start_time):NaN;
 const end=reference.reset_end_time?Date.parse(reference.reset_end_time):NaN;
 const hasWindow=Number.isFinite(start)&&Number.isFinite(end)&&end>start;
 let points=null;
 if(hasWindow){
  const collected=[];
  for(const sample of samples){
   const time=Date.parse(sample.sampled_at||'');
   if(!Number.isFinite(time)||time<start||time>end)continue;
   const left=qdModel(sample).left;
   if(left==null)continue;
   collected.push({t:Math.max(start,Math.min(end,time)),y:left});
  }
  if(collected.length)points=collected;
 }
 let pace=null;
 if(points){
  const expected=Math.max(0,Math.min(100,(now-start)/(end-start)*100));
  const actual=Math.max(0,Math.min(100,100-points[points.length-1].y));
  pace={expectedUsedPercent:expected,reserve:actual<expected,delta:actual-expected};
 }
 return {points,windowStart:hasWindow?start:null,windowEnd:hasWindow?end:null,pace,
  cycles:qdCycles(samples,hasWindow?end-start:null),hourly:qdHourly(samples)};
}
// 完整周期峰值（app ModelUtilizationHistory.cycles 语义）：按 reset_end_time ±120s 合并取 max(used)，
// 剔除进行中的周期（resetsAt>now），短窗口（<24h，约 5h 周期）取最近 30 根否则 12 根。
function qdCycles(samples,windowDuration){
 const now=Date.now(),buckets=[];
 for(const sample of samples){
  if(!sample.reset_end_time)continue;
  const resetsAt=Date.parse(sample.reset_end_time);
  if(!Number.isFinite(resetsAt))continue;
  const used=qdModel(sample).used;
  if(used==null||used<=0)continue;
  const bucket=buckets.find(item=>Math.abs(item.resetsAt-resetsAt)<=120000);
  if(bucket){bucket.resetsAt=Math.max(bucket.resetsAt,resetsAt);bucket.peakPercent=Math.max(bucket.peakPercent,used);}
  else buckets.push({resetsAt,peakPercent:used});
 }
 return buckets.filter(bucket=>bucket.resetsAt<=now).sort((a,b)=>a.resetsAt-b.resetsAt)
  .slice(windowDuration!=null&&windowDuration<86400000?-30:-12)
  .map(bucket=>({resetsAt:bucket.resetsAt,peakPercent:bucket.peakPercent}));
}
// 每 UTC 小时消耗（48h）：相邻样本的剩余降幅记入后一个样本所在小时，首样本计 0。
function qdHourly(samples){
 const buckets=[],byHour=new Map();let previous=null;
 for(const sample of samples){
  const time=Date.parse(sample.sampled_at||'');
  if(!Number.isFinite(time))continue;
  const left=qdModel(sample).left;
  if(left==null)continue;
  const date=new Date(time),hourStart=Date.UTC(date.getUTCFullYear(),date.getUTCMonth(),date.getUTCDate(),date.getUTCHours());
  let bucket=byHour.get(hourStart);
  if(!bucket){bucket={hourStart,consumedPercent:0};byHour.set(hourStart,bucket);buckets.push(bucket);}
  if(previous!=null)bucket.consumedPercent+=Math.max(0,previous-left);
  previous=left;
 }
 return buckets.slice(-48);
}
function qdCard(acc){
 const open=qd.open.has(acc.key),card=document.createElement('div');
 card.className='qd-card'+(open?' is-open':'');
 const head=document.createElement('button');head.type='button';head.className='qd-head';
 head.setAttribute('aria-expanded',open?'true':'false');
 const caret=document.createElement('span');caret.className='qd-caret';caret.textContent=open?'▾':'▸';
 const provider=document.createElement('span');provider.className='qd-provider';provider.textContent=acc.provider;
 const name=document.createElement('span');name.className='qd-account';name.textContent=acc.account_name||T.unnamed;
 const chip=document.createElement('span');chip.className='qd-team';chip.textContent=acc.team_name;
 const time=document.createElement('span');time.className='qd-time';time.textContent=dayMinute(acc.latest);
 head.append(caret,provider,name,chip,time);
 head.addEventListener('click',()=>{if(qd.open.has(acc.key))qd.open.delete(acc.key);else qd.open.add(acc.key);renderQuotaCards();});
 card.append(head);
 const summary=document.createElement('p');summary.className='qd-summary';
 summary.textContent=`${T.modelsCount(acc.rows.length)} · ${T.minLeft(acc.worst)}`;
 card.append(summary);
 if(open){
  let history=qd.history.get(acc.key);
  if(!history){qdLoadHistory(acc);history=qd.history.get(acc.key);}
  const body=document.createElement('div');body.className='qd-models';
  for(const row of acc.rows){
   const box=document.createElement('div');box.className='qd-model';
   const samples=history.status==='ready'?history.samples.filter(sample=>sample.model_id===row.item.model_id):[];
   const analysis=samples.length?qdModelAnalysis(row.item,samples,Date.now()):null;
   const modelHead=document.createElement('div');modelHead.className='qd-model-head';
   const modelName=document.createElement('span');modelName.textContent=row.item.model_name||row.item.model_id;
   const remaining=document.createElement('span');remaining.className='qd-remaining';remaining.textContent=row.right;
   if(row.used!=null)remaining.style.color=qdTint(row.used,row.left);
   modelHead.append(modelName,remaining);
   const bar=document.createElement('div');bar.className='qd-bar';
   const fill=document.createElement('div');fill.className='qd-bar-fill';
   fill.style.width=(row.used==null?0:row.used)+'%';
   if(row.used!=null)fill.style.background=qdTint(row.used,row.left);
   bar.append(fill);
   const meta=document.createElement('div');meta.className='qd-meta';
   if(analysis&&analysis.pace){
    const paceSpan=document.createElement('span');
    paceSpan.textContent=T.paceLabel(analysis.pace.delta);
    paceSpan.style.color=analysis.pace.delta>2?'#9b4a32':'#69746c';
    meta.append(paceSpan);
   }
   const parts=[qdWeeklyText(row.item),row.item.reset_start_time?`${T.resets} ${dayMinute(row.item.reset_start_time)} ~ ${dayMinute(row.item.reset_end_time)}`:null,
    `${T.device} ${row.item.device_id?row.item.device_id.slice(0,8)+'…':'—'}`,`${T.reported} ${dayMinute(row.item.sampled_at)}`].filter(Boolean);
   parts.forEach((text,index)=>{if(index||(analysis&&analysis.pace)){const dot=document.createElement('span');dot.textContent='·';meta.append(dot);}
    const span=document.createElement('span');span.textContent=text;meta.append(span);});
   box.append(modelHead,bar,meta);
   const chartsModule=window.AdminQuotaCharts;
   if(analysis&&chartsModule){
    if(analysis.points){
     const chart=document.createElement('div');chart.className='qd-chart';
     chartsModule.curve(chart,{points:analysis.points,windowStart:analysis.windowStart,windowEnd:analysis.windowEnd,
      tint:qdTint(row.used,row.left),
      pace:analysis.pace?{expectedUsedPercent:analysis.pace.expectedUsedPercent,reserve:analysis.pace.reserve}:null});
     box.append(chart);
    }
    if(analysis.cycles.length||analysis.hourly.length){
     const miniRows=document.createElement('div');miniRows.className='qd-mini-rows';
     if(analysis.cycles.length){
      const half=document.createElement('div');half.className='qd-mini';
      const label=document.createElement('span');label.className='qd-mini-label';label.textContent=T.recentCycles;
      const bars=document.createElement('div');
      chartsModule.cycleBars(bars,{cycles:analysis.cycles,tint:qdTint(row.used,row.left)});
      half.append(label,bars);miniRows.append(half);
     }
     if(analysis.hourly.length){
      const half=document.createElement('div');half.className='qd-mini';
      const label=document.createElement('span');label.className='qd-mini-label';label.textContent=T.hourlyUse;
      const bars=document.createElement('div');
      chartsModule.hourlyBars(bars,{buckets:analysis.hourly});
      half.append(label,bars);miniRows.append(half);
     }
     if(miniRows.children.length)box.append(miniRows);
    }
   }else if(!analysis){
    const state=document.createElement('div');state.className='qd-state';
    state.textContent=history.status==='error'?T.historyFailed:history.status==='ready'?T.noHistory:T.loadingHistory;
    box.append(state);
   }
   body.append(box);
  }
  card.append(body);
 }
 return card;
}
function renderQuotaCards(){
 const grid=$('quota-cards');grid.replaceChildren();
 const team=$('data-team').value;
 const items=quotaItems.filter(item=>!team||item.team_id===team);
 if(!items.length){const empty=document.createElement('p');empty.className='empty';empty.textContent=T.noData;grid.append(empty);qd.accounts=[];return;}
 const accounts=new Map();
 for(const item of items){
  const key=item.team_id+'|'+item.provider+'|'+(item.account_name??'');
  if(!accounts.has(key))accounts.set(key,{key,team_id:item.team_id,team_name:item.team_name||item.team_id,provider:item.provider,account_name:item.account_name,models:[]});
  accounts.get(key).models.push(item);
 }
 qd.accounts=[...accounts.values()].map(account=>{
  const rows=account.models.map(qdModel).sort((a,b)=>(a.left??101)-(b.left??101));
  const lefts=rows.map(row=>row.left).filter(value=>value!=null);
  return {...account,rows,worst:lefts.length?Math.min(...lefts):null,
   latest:account.models.reduce((max,model)=>model.sampled_at>max?model.sampled_at:max,'')};
 }).sort((a,b)=>(a.worst??101)-(b.worst??101)||(a.latest<b.latest?1:a.latest>b.latest?-1:0));
 const keys=new Set(qd.accounts.map(account=>account.key));
 for(const key of [...qd.open])if(!keys.has(key))qd.open.delete(key);
 for(const account of qd.accounts)grid.append(qdCard(account));
}
function setQuotaView(view){
 qd.view=view;try{localStorage.setItem('aqb-admin-quota-view',view)}catch{}
 $('quota-cards').hidden=view!=='cards';
 $('quota-table-wrap').hidden=view==='cards';
 $('qd-view-cards').className='qd-tab'+(view==='cards'?' active':'');
 $('qd-view-list').className='qd-tab'+(view==='cards'?'':' active');
 $('qd-expand-all').hidden=view!=='cards';
 $('qd-collapse-all').hidden=view!=='cards';
}
$('qd-view-cards').addEventListener('click',()=>setQuotaView('cards'));
$('qd-view-list').addEventListener('click',()=>setQuotaView('list'));
$('qd-expand-all').addEventListener('click',()=>{for(const account of qd.accounts)qd.open.add(account.key);renderQuotaCards();});
$('qd-collapse-all').addEventListener('click',()=>{qd.open.clear();renderQuotaCards();});
setQuotaView(qd.view);
$('data-refresh').addEventListener('click',loadBusinessData);$('data-team').addEventListener('change',()=>{loadTeamAccounts();renderQuotaDetail();renderQuotaCards();});
