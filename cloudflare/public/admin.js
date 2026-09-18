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
 deleteQuotaHistory:EN?'Delete quota history':'删除额度历史',
 confirmDeleteQuota:(t,p,n)=>EN?`Delete team ${t}'s ${p} / ${n} quota history? Other teams are unaffected. Reporting devices will create new snapshots.`:`删除团队 ${t} 的 ${p} / ${n} 额度历史？其他团队不受影响。正在上报的设备会产生新快照。`,
 deleteRetry:EN?'Delete failed — retry.':'删除失败，请重试。',
 sessionExpired:EN?'Session expired — sign in again.':'登录已过期，请重新登录。',
 dataLoadFailed:EN?'Business data failed to load — confirm the team database migration is complete.':'业务数据加载失败，请确认团队数据库迁移已完成。',
 teamAccountsFailed:EN?'Team accounts failed to load.':'团队账号加载失败。',
 d1:(r,w)=>EN?`D1 today: ${r} rows read · ${w} rows written`:`D1 今日读取 ${r} 行 · 写入 ${w} 行`,
 d1Unavailable:EN?'D1 monitoring unavailable or not configured.':'D1 监控暂不可用或尚未配置。',
};
let loading=false;
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

async function loadBusinessData(){
 try{
  const [teams,legacy,audit]=await Promise.all([api('data/teams'),api('data/legacy/accounts'),api('data/audit')]);
  $('data-error').textContent='';
  renderTable('team-rows',teams.teams,[r=>r.team_name,r=>r.team_id,r=>r.members,r=>r.devices,r=>r.events]);
  const select=$('data-team'),previous=select.value;select.replaceChildren(new Option(T.selectTeam,''));
  for(const team of teams.teams)select.add(new Option(team.team_name,team.team_id));
  if(teams.teams.some(t=>t.team_id===previous))select.value=previous;
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
 }catch{$('data-error').textContent=T.teamAccountsFailed;}
}
$('data-refresh').addEventListener('click',loadBusinessData);$('data-team').addEventListener('change',loadTeamAccounts);
