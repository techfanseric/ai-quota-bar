const $=id=>document.getElementById(id);
const EN=document.documentElement.lang.indexOf('en')===0;
const L=EN?'en-US':'zh-CN';
const T={
 unpriced:EN?'Unpriced':'未定价',
 loadFailed:EN?'Load failed — showing the previous result. Refresh to retry.':'数据加载失败，当前显示为上一次结果。请稍后刷新。',
 unavailable:EN?'Service unavailable — try again later.':'服务暂不可用，请稍后重试。',
 updated:EN?'Updated ':'更新于 ',
 inviteInfo:(rot,limit)=>EN?`The invite code is shown only once when created or rotated; last rotated ${rot}. Rotating invalidates the old code immediately — existing members are unaffected. The team limit is ${limit} members.`:`邀请码只在创建或轮换时显示一次，上次轮换 ${rot}。轮换后旧码立即失效，已加入的成员不受影响。团队上限 ${limit} 名成员。`,
 noMembers:EN?'No members yet — send the invite code to teammates to enter in the app\'s settings.':'还没有成员加入。把邀请码发给队友，让他们在 App 设置中填写。',
 unknownAccount:EN?'Unknown account':'账号未知',
 noUsage:EN?'No reported usage in the selected range.':'所选范围内还没有上报的用量。',
 removed:EN?' · removed':' · 已移除',
 lastSeen:EN?' · last seen ':' · 最近上报 ',
 remove:EN?'Remove':'移除',
 noDevices:EN?'No devices':'暂无设备',
 disableAll:EN?'Disable all of this member\'s devices':'停用成员全部设备',
 confirmDisable:n=>EN?`Disable all devices of ${n}? History is kept.`:`停用 ${n} 的全部设备？历史记录保留。`,
 disableFailed:EN?'Disabling failed — try again.':'停用失败，请重试。',
 confirmRemoveDevice:EN?'Remove this device? It stops reporting immediately; recorded usage is kept.':'移除这台设备？它将立即停止上报；已入账的历史用量保留。',
 sessionExpired:EN?'Session expired — sign in again.':'登录已过期，请重新登录。',
 removeFailed:EN?'Removal failed — try again later.':'移除失败，请稍后重试。',
 createRate:EN?'Too many requests — try again in an hour.':'创建过于频繁，请 1 小时后再试。',
 teamsDisabled:EN?'Self-serve teams aren\'t enabled on this service yet.':'自助团队尚未在此服务开启。',
 createFailed:EN?'Creation failed — try again later.':'创建失败，请稍后重试。',
 autoLoginFailed:EN?'Auto sign-in failed — sign in manually with the team ID and admin password.':'自动登录失败，请用团队 ID 和管理密码手动登录。',
 attemptsRate:EN?'Too many attempts — try again in 15 minutes.':'尝试过于频繁，请 15 分钟后再试。',
 badCredentials:EN?'Incorrect team ID or admin password.':'团队 ID 或管理密码不正确。',
 loginUnavailable:EN?'Sign-in service unavailable — try again later.':'登录服务暂不可用，请稍后重试。',
 rotateFailed:EN?'Rotation failed — try again later.':'轮换失败，请稍后重试。',
 unnamed:EN?'Unnamed':'未命名',
 deleteQuotaHistory:EN?'Delete quota history':'删除额度历史',
 confirmDeleteQuota:(p,n)=>EN?`Delete this team's ${p} / ${n} quota history? Member usage and other teams are unaffected.`:`删除本团队 ${p} / ${n} 的额度历史？成员用量和其他团队不受影响。`,
 deleteFailed:EN?'Delete failed — refresh or sign in again.':'删除失败，请刷新或重新登录。',
 quotaUnavailable:EN?'Quota data unavailable — refresh later.':'额度数据暂不可用，请稍后刷新。',
};
let pendingPassword=null,loading=false,sessionGeneration=0,canManage=false,activeTeam=null;
function invalidateSession(){sessionGeneration++;loading=false;activeTeam=null;if(typeof window!=='undefined')window.TeamCharts?.invalidate();}
async function api(path,options={}) {
	const headers=new Headers(options.headers);if(activeTeam)headers.set('X-AQB-Team',activeTeam);
	const response=await fetch('/v1/team/'+path,{credentials:'same-origin',...options,headers});
	const data=await response.json().catch(()=>({}));
	if(!response.ok){const error=new Error(data.error||'request_failed');error.status=response.status;throw error;}
	return data;
}
function entryView(){ invalidateSession();$('loading').hidden=true;$('dashboard').hidden=true;$('credentials').hidden=true;$('logout').hidden=true;$('entry').hidden=false; }
function dashboardView(){ $('loading').hidden=true;$('entry').hidden=true;$('credentials').hidden=true;$('dashboard').hidden=false;$('logout').hidden=false; }
const compact=new Intl.NumberFormat(L,{notation:'compact',maximumFractionDigits:2});
const plain=new Intl.NumberFormat(L);
const tokens=value=>value>=1e6?compact.format(value):plain.format(value);
const cache=rate=>rate==null?'—':(rate*100).toFixed(1)+'%';
const cost=row=>row.pricedRecords>0?'$'+row.costUSD.toFixed(4):T.unpriced;
const day=value=>value?value.replace('T',' ').slice(0,16)+' UTC':'—';
function copyText(value){ if(navigator.clipboard) navigator.clipboard.writeText(value).catch(()=>{}); }
document.addEventListener('click',event=>{ const source=event.target.closest('[data-copy]'); if(source) copyText($(source.dataset.copy).textContent); });

async function load(){
	if(loading)return;loading=true;const generation=sessionGeneration;$('refresh').disabled=true;$('error').hidden=true;
	try{
		const data=await api('overview?days='+$('days').value);
        if(generation!==sessionGeneration)return;
		dashboardView();
		renderOverview(data);
        await loadQuota();
	}catch(error){
        if(generation!==sessionGeneration)return;
		if(error.status===401||error.status===409){entryView();$('login-error').textContent=error.status===409?(EN?'Team sign-in changed in another tab. Reopen this team from the app.':'团队登录已在其他页面切换，请从 App 重新打开当前团队。'):'';}
		else if(!$('dashboard').hidden){$('error').hidden=false;$('error').textContent=T.loadFailed;}
		else{entryView();$('login-error').textContent=T.unavailable;}
	}finally{if(generation===sessionGeneration){loading=false;$('refresh').disabled=false;}}
}
function renderOverview(data){
 activeTeam=data.team.teamID;
 const chartGeneration=sessionGeneration;if(typeof window!=='undefined')window.TeamCharts?.update(data,api,()=>chartGeneration===sessionGeneration);
 canManage=data.access?.canManage===true;
 $("team-access").textContent=canManage?(EN?"Manager · Manage this team":"管理员 · 可管理当前团队"):(EN?"Member · Read-only access to this team":"团队成员 · 可查看本团队成员、设备和账号用量");
 $("invite-panel").hidden=!canManage;
 $("quota-management-note").hidden=!canManage;
 $("quota-action-heading").textContent=canManage?(EN?"Actions":"操作"):(EN?"Access":"权限");
	$('team-title').textContent=data.team.teamName;
	$('updated').textContent=T.updated+data.generatedAt.replace('T',' ').slice(0,19)+' UTC · '+data.team.teamID;
	$('invite-info').textContent=T.inviteInfo(day(data.team.inviteRotatedAt),data.team.memberLimit);
	const usageByMember=new Map(data.usage.member.map(row=>[row.memberID,row]));
	const rows=$('member-rows');rows.replaceChildren();
	for(const member of data.members){
		const usage=usageByMember.get(member.memberID);
		const row=document.createElement('tr');
		const cells=[member.memberName,usage?tokens(usage.input+usage.output):'0',usage?plain.format(usage.records):'0',usage?cache(usage.cacheHitRate):'—',usage?cost(usage):'—'];
		for(const text of cells){const cell=document.createElement('td');cell.textContent=text;row.append(cell);}
		row.append(devicesCell(member,data));
		rows.append(row);
	}
	if(!data.members.length){const row=document.createElement('tr'),cell=document.createElement('td');cell.colSpan=6;cell.textContent=T.noMembers;row.append(cell);rows.append(row);}
	const accounts=$('account-rows');accounts.replaceChildren();
	for(const account of data.usage.account){
		const row=document.createElement('tr');
		for(const text of [account.id==='unknown'?T.unknownAccount:account.id.slice(0,12)+'…',tokens(account.input+account.output),plain.format(account.records),cache(account.cacheHitRate),cost(account)]){const cell=document.createElement('td');cell.textContent=text;row.append(cell);}
		accounts.append(row);
	}
	if(!data.usage.account.length){const row=document.createElement('tr'),cell=document.createElement('td');cell.colSpan=5;cell.textContent=T.noUsage;row.append(cell);accounts.append(row);}
}
function devicesCell(member,data){
	const cell=document.createElement('td');
	const details=document.createElement('details');
	const summary=document.createElement('summary');
	summary.textContent=member.devices.filter(device=>!device.revoked).length+' / '+member.devices.length;
	details.append(summary);
	const list=document.createElement('div');list.className='device-list';
	for(const device of member.devices){
		const line=document.createElement('div');
		const label=document.createElement('span');
		label.textContent=device.deviceID.slice(0,8)+'…'+(device.revoked?T.removed:T.lastSeen+day(device.lastEventAt));
		line.append(label);
		if(canManage&&!device.revoked){const button=document.createElement('button');button.type='button';button.textContent=T.remove;button.addEventListener('click',()=>revokeDevice(device.deviceID));line.append(button);}
		list.append(line);
	}
	if(!member.devices.length)list.textContent=T.noDevices;
	details.append(list);
 const remove=document.createElement('button');remove.textContent=T.disableAll;remove.type='button';
 remove.addEventListener('click',async()=>{if(!confirm(T.confirmDisable(member.memberName)))return;
 try{await api('members/revoke',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({memberID:member.memberID})});await load();}catch{$('error').hidden=false;$('error').textContent=T.disableFailed;}});
 if(canManage)details.append(remove);cell.append(details);return cell;
}
async function revokeDevice(deviceID){
	if(!confirm(T.confirmRemoveDevice))return;
	try{await api('devices/revoke',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({deviceID})});await load();}
	catch(error){$('error').hidden=false;$('error').textContent=error.status===401?T.sessionExpired:T.removeFailed;}
}
$('create-form').addEventListener('submit',async event=>{
	event.preventDefault();const button=event.currentTarget.querySelector('button');button.disabled=true;$('create-error').textContent='';
	try{
		const data=await api('create',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({teamName:$('team-name').value})});
		$('new-team-id').textContent=data.teamID;$('new-invite').textContent=data.inviteCode;$('new-password').textContent=data.loginPassword;
		pendingPassword=data.loginPassword;$('team-name').value='';
		$('entry').hidden=true;$('credentials').hidden=false;$('loading').hidden=true;
	}catch(error){$('create-error').textContent=error.status===429?T.createRate:error.status===503?T.teamsDisabled:T.createFailed;}
	finally{button.disabled=false;}
});
$('open-dashboard').addEventListener('click',async()=>{
    invalidateSession();
	const teamID=$('new-team-id').textContent;
	try{await api('login',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({teamID,password:pendingPassword})});pendingPassword=null;await load();}
	catch{$('credentials').hidden=true;entryView();$('login-error').textContent=T.autoLoginFailed;}
});
$('login-form').addEventListener('submit',async event=>{
    invalidateSession();
	event.preventDefault();const button=event.currentTarget.querySelector('button');button.disabled=true;$('login-error').textContent='';
	try{await api('login',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({teamID:$('team-id').value.trim(),password:$('password').value})});$('password').value='';await load();}
	catch(error){$('login-error').textContent=error.status===429?T.attemptsRate:error.status===401?T.badCredentials:T.loginUnavailable;}
	finally{button.disabled=false;}
});
$('logout').addEventListener('click',async()=>{entryView();try{await api('logout',{method:'POST'});}catch{}entryView();$('password').value='';});
$('rotate').addEventListener('click',async()=>{
	try{const data=await api('invite/rotate',{method:'POST'});$('rotated-invite').textContent=data.inviteCode;$('rotate-result').hidden=false;await load();}
	catch(error){$('error').hidden=false;$('error').textContent=error.status===401?T.sessionExpired:T.rotateFailed;}
});
$('days').addEventListener('change',load);$('refresh').addEventListener('click',load);
async function bootstrap(){
 const ticket=typeof location==='undefined'?null:new URLSearchParams(location.hash.slice(1)).get('handoff');
 if(ticket){
  history.replaceState(null,'',location.pathname+location.search);
  invalidateSession();const generation=sessionGeneration;
  $('dashboard').hidden=true;$('entry').hidden=true;$('loading').hidden=false;$('logout').hidden=true;
  try{const result=await api('redeem',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({ticket})});if(generation!==sessionGeneration)return;activeTeam=result.teamID||null;}
  catch{if(generation!==sessionGeneration)return;entryView();$('login-error').textContent=EN?'This link expired or was already used. Return to the app and open your team again.':'直达链接已过期或已使用。请返回 App 再次点击「查看团队」或「管理团队」。';return;}
 }
 await load();
}
bootstrap();
if(typeof window!=='undefined')window.addEventListener('hashchange',()=>{if(new URLSearchParams(location.hash.slice(1)).has('handoff'))bootstrap();});

async function loadQuota(){
 const generation=sessionGeneration;
 try{const data=await api('accounts');if(generation!==sessionGeneration)return;const rows=$('quota-rows');rows.replaceChildren();$('quota-error').textContent='';
  for(const item of data.accounts){const row=document.createElement('tr');for(const text of [item.provider,item.account_name||T.unnamed,item.model_count,item.sample_count]){const td=document.createElement('td');td.textContent=text;row.append(td);}
   const td=document.createElement('td'),button=document.createElement('button');button.textContent=T.deleteQuotaHistory;button.type='button';button.addEventListener('click',async()=>{
    if(!confirm(T.confirmDeleteQuota(item.provider,item.account_name||T.unnamed)))return;
    button.disabled=true;try{await api('accounts?'+new URLSearchParams({provider:item.provider,account_name:item.account_name}),{method:'DELETE'});await loadQuota();}catch{if(generation!==sessionGeneration)return;$('quota-error').textContent=T.deleteFailed;}
   });if(canManage)td.append(button);else td.textContent=EN?'Read only':'只读';row.append(td);rows.append(row);
  }
 }catch{if(generation===sessionGeneration)$('quota-error').textContent=T.quotaUnavailable;}
}
