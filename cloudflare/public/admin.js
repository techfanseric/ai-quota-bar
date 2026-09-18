const $=id=>document.getElementById(id);
let loading=false;
async function api(path,options={}) {
 const response=await fetch('/v1/admin/'+path,{credentials:'same-origin',...options});
 const data=await response.json();if(!response.ok){const error=new Error(data.error||'request_failed');error.status=response.status;throw error;}return data;
}
function loginView(){ $('loading').hidden=true;$('dashboard').hidden=true;$('logout').hidden=true;$('login').hidden=false;}
function renderTable(id,rows,columns){const body=$(id);body.replaceChildren();if(!rows.length){const row=document.createElement('tr'),cell=document.createElement('td');cell.colSpan=columns.length;cell.textContent='暂无数据';row.append(cell);body.append(row);return;}for(const data of rows){const row=document.createElement('tr');for(const column of columns){const cell=document.createElement('td');cell.textContent=String(column(data));row.append(cell);}body.append(row);}}
async function loadFeedback(){try{renderFeedback(await api('feedback?limit=50'));}catch(error){if(error.status===401)return;if(!$('dashboard').hidden)$('feedback-error').hidden=false;}}
function renderFeedback(data){$('feedback-counts').textContent=`公开 ${data.counts.published} · 已隐藏 ${data.counts.hidden}`;$('feedback-error').hidden=true;$('feedback-empty').hidden=data.items.length>0;const rows=$('feedback-rows');rows.replaceChildren();for(const item of data.items){const row=document.createElement('tr');const cell=text=>{const node=document.createElement('td');node.textContent=text;return node;};row.append(cell(item.createdAt.slice(0,16).replace('T',' ')),cell(item.source==='app'?'App':'网页'),cell(item.nickname||'匿名用户'),cell(item.contact||'—'),cell(item.message),cell((item.appVersion?'v'+item.appVersion:'—')+(item.osVersion?' / macOS '+item.osVersion:'')));const status=document.createElement('td'),badge=document.createElement('span');badge.className='status '+item.status;badge.textContent=item.status==='published'?'公开':'已隐藏';status.append(badge);row.append(status);const actions=document.createElement('td');const toggle=document.createElement('button');toggle.type='button';toggle.textContent=item.status==='published'?'隐藏':'恢复';toggle.addEventListener('click',async()=>{toggle.disabled=true;try{await api('feedback/status',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({id:item.id,status:item.status==='published'?'hidden':'published'})});await loadFeedback();}catch{$('feedback-error').hidden=false;toggle.disabled=false;}});const remove=document.createElement('button');remove.type='button';remove.className='danger';remove.textContent='删除';remove.addEventListener('click',async()=>{if(!confirm('确定删除这条反馈？删除后无法恢复。'))return;remove.disabled=true;try{await api('feedback?id='+encodeURIComponent(item.id),{method:'DELETE'});await loadFeedback();}catch{$('feedback-error').hidden=false;remove.disabled=false;}});actions.append(toggle,remove);row.append(actions);rows.append(row);}}
function chart(rows){const svg=$('chart');svg.replaceChildren();const ns='http://www.w3.org/2000/svg';const max=Math.max(3,Math.ceil(Math.max(0,...rows.flatMap(r=>[r.active,r.newInstalls]))/3)*3);const element=(tag,attrs,text)=>{const node=document.createElementNS(ns,tag);for(const [k,v] of Object.entries(attrs))node.setAttribute(k,v);if(text!==undefined)node.textContent=text;svg.append(node);return node;};
 for(let i=0;i<4;i++){const y=15+i*65;element('line',{x1:35,x2:990,y1:y,y2:y,stroke:'#d9dfd6','stroke-width':1});element('text',{x:25,y:y+4,'text-anchor':'end',fill:'#69746c','font-size':10},String(Math.round(max*(3-i)/3)));}
 for(const [key,color] of [['active','#507a59'],['newInstalls','#b0bd9c']]){const points=rows.map((r,i)=>[35+i*955/Math.max(1,rows.length-1),210-r[key]/max*195]);element('polyline',{points:points.map(p=>p.join(',')).join(' '),fill:'none',stroke:color,'stroke-width':2.5});rows.forEach((r,i)=>{const node=element('circle',{cx:points[i][0],cy:points[i][1],r:3,fill:color});const title=document.createElementNS(ns,'title');title.textContent=r.day+' · '+(key==='active'?'活跃':'新增')+' '+r[key];node.append(title);});}
 svg.setAttribute('aria-label',`近 ${rows.length} 天每日活跃与新增设备趋势，下方可展开每日数据`);$('chart-from').textContent=rows[0]?.day||'';$('chart-to').textContent=rows.at(-1)?.day||'';
}
async function load(){if(loading)return;loading=true;$('refresh').disabled=true;$('error').hidden=true;try{const data=await api('overview?days='+$('days').value);$('login').hidden=true;$('loading').hidden=true;$('dashboard').hidden=false;$('logout').hidden=false;for(const [key,value]of Object.entries(data.metrics))if($(key))$(key).textContent=Number(value).toLocaleString('zh-CN');$('updated').textContent='更新于 '+data.generatedAt.replace('T',' ').slice(0,19)+' UTC';$('coverage-since').textContent=data.coverageSince?'最早接入：'+data.coverageSince.slice(0,10)+'（UTC）':'尚无设备开启匿名统计';$('empty').hidden=data.metrics.total>0;chart(data.trend);renderTable('daily-rows',[...data.trend].reverse(),[r=>r.day,r=>r.active,r=>r.newInstalls]);for(const [id,rows,label] of [['version-rows',data.versions,r=>r.version+' ('+r.build+')'],['system-rows',data.systems,r=>'macOS '+r.version]]){const total=data.metrics.reporting_month;renderTable(id,rows,[label,r=>r.installs,r=>total?(r.installs/total*100).toFixed(1)+'%':'—']);}$('legacy-devices').textContent=data.legacy.syncedDevices;$('legacy-members').textContent=data.legacy.configuredMembers;await loadBusinessData();}catch(error){if(error.status===401){loginView();}else if(!$('dashboard').hidden){$('error').hidden=false;$('error').textContent='数据加载失败，当前显示为上一次结果。请稍后刷新。';}else{loginView();$('login-error').textContent='服务暂不可用，请稍后重试。';}}finally{loading=false;$('refresh').disabled=false;}}
$('login-form').addEventListener('submit',async event=>{event.preventDefault();const button=event.currentTarget.querySelector('button');button.disabled=true;$('login-error').textContent='';try{await api('login',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({password:$('password').value})});$('password').value='';await load();loadFeedback();}catch(error){$('login-error').textContent=error.status===429?'尝试过于频繁，请 15 分钟后再试。':error.status===401?'管理员密码不正确。':'登录服务暂不可用，请稍后重试。';}finally{button.disabled=false;}});
$('logout').addEventListener('click',async()=>{try{await api('logout',{method:'POST'});loginView();$('password').value='';}catch{$('error').hidden=false;$('error').textContent='退出失败，请重试。';}});
$('days').addEventListener('change',load);$('refresh').addEventListener('click',()=>{load();loadFeedback();});load();loadFeedback();

async function loadBusinessData(){
 try{
  const [teams,legacy,audit]=await Promise.all([api('data/teams'),api('data/legacy/accounts'),api('data/audit')]);
  $('data-error').textContent='';
  renderTable('team-rows',teams.teams,[r=>r.team_name,r=>r.team_id,r=>r.members,r=>r.devices,r=>r.events]);
  const select=$('data-team'),previous=select.value;select.replaceChildren(new Option('选择团队',''));
  for(const team of teams.teams)select.add(new Option(team.team_name,team.team_id));
  if(teams.teams.some(t=>t.team_id===previous))select.value=previous;
  renderTable('legacy-account-rows',legacy.accounts,[r=>r.provider,r=>r.account_name||'未命名',r=>r.model_count,r=>r.sample_count]);
  renderTable('audit-rows',audit.items,[r=>r.created_at,r=>r.team_id,r=>r.actor,r=>r.action,r=>r.target]);
  await loadTeamAccounts();
 }catch(error){$('data-error').textContent=error.status===401?'登录已过期，请重新登录。':'业务数据加载失败，请确认团队数据库迁移已完成。';}
 try{const d=await api('d1-usage');$('d1-status').textContent=`D1 今日读取 ${Number(d.rowsRead).toLocaleString()} 行 · 写入 ${Number(d.rowsWritten).toLocaleString()} 行`;}catch{$('d1-status').textContent='D1 监控暂不可用或尚未配置。';}
}
async function loadTeamAccounts(){
 const team=$('data-team').value,rows=$('quota-rows');rows.replaceChildren();if(!team)return;
 try{const data=await api('data/accounts?team_id='+encodeURIComponent(team));if($('data-team').value!==team)return;
  for(const item of data.accounts){const row=document.createElement('tr');for(const text of [item.provider,item.account_name||'未命名',item.model_count,item.sample_count,item.latest_sampled_at]){const td=document.createElement('td');td.textContent=text;row.append(td);}
   const td=document.createElement('td'),button=document.createElement('button');button.textContent='删除额度历史';button.type='button';button.addEventListener('click',async()=>{
    if(!confirm(`删除团队 ${team} 的 ${item.provider} / ${item.account_name||'未命名'} 额度历史？其他团队不受影响。正在上报的设备会产生新快照。`))return;
    button.disabled=true;try{await api('data/accounts?'+new URLSearchParams({team_id:team,provider:item.provider,account_name:item.account_name}),{method:'DELETE'});await loadBusinessData();}catch{$('data-error').textContent='删除失败，请重试。';button.disabled=false;}
   });td.append(button);row.append(td);rows.append(row);
  }
 }catch{$('data-error').textContent='团队账号加载失败。';}
}
$('data-refresh').addEventListener('click',loadBusinessData);$('data-team').addEventListener('change',loadTeamAccounts);
