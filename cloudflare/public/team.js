const $=id=>document.getElementById(id);
let pendingPassword=null,loading=false,sessionGeneration=0;
function invalidateSession(){sessionGeneration++;loading=false;}
async function api(path,options={}) {
	const response=await fetch('/v1/team/'+path,{credentials:'same-origin',...options});
	const data=await response.json().catch(()=>({}));
	if(!response.ok){const error=new Error(data.error||'request_failed');error.status=response.status;throw error;}
	return data;
}
function entryView(){ invalidateSession();$('loading').hidden=true;$('dashboard').hidden=true;$('credentials').hidden=true;$('logout').hidden=true;$('entry').hidden=false; }
function dashboardView(){ $('loading').hidden=true;$('entry').hidden=true;$('credentials').hidden=true;$('dashboard').hidden=false;$('logout').hidden=false; }
const compact=new Intl.NumberFormat('zh-CN',{notation:'compact',maximumFractionDigits:2});
const plain=new Intl.NumberFormat('zh-CN');
const tokens=value=>value>=1e6?compact.format(value):plain.format(value);
const cache=rate=>rate==null?'—':(rate*100).toFixed(1)+'%';
const cost=row=>row.pricedRecords>0?'$'+row.costUSD.toFixed(4):'未定价';
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
		if(error.status===401)entryView();
		else if(!$('dashboard').hidden){$('error').hidden=false;$('error').textContent='数据加载失败，当前显示为上一次结果。请稍后刷新。';}
		else{entryView();$('login-error').textContent='服务暂不可用，请稍后重试。';}
	}finally{if(generation===sessionGeneration){loading=false;$('refresh').disabled=false;}}
}
function renderOverview(data){
	$('team-title').textContent=data.team.teamName;
	$('updated').textContent='更新于 '+data.generatedAt.replace('T',' ').slice(0,19)+' UTC · '+data.team.teamID;
	$('invite-info').textContent='邀请码只在创建或轮换时显示一次，上次轮换 '+day(data.team.inviteRotatedAt)+'。轮换后旧码立即失效，已加入的成员不受影响。团队上限 '+data.team.memberLimit+' 名成员。';
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
	if(!data.members.length){const row=document.createElement('tr'),cell=document.createElement('td');cell.colSpan=6;cell.textContent='还没有成员加入。把邀请码发给队友，让他们在 App 设置中填写。';row.append(cell);rows.append(row);}
	const accounts=$('account-rows');accounts.replaceChildren();
	for(const account of data.usage.account){
		const row=document.createElement('tr');
		for(const text of [account.id==='unknown'?'账号未知':account.id.slice(0,12)+'…',tokens(account.input+account.output),plain.format(account.records),cache(account.cacheHitRate),cost(account)]){const cell=document.createElement('td');cell.textContent=text;row.append(cell);}
		accounts.append(row);
	}
	if(!data.usage.account.length){const row=document.createElement('tr'),cell=document.createElement('td');cell.colSpan=5;cell.textContent='所选范围内还没有上报的用量。';row.append(cell);accounts.append(row);}
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
		label.textContent=device.deviceID.slice(0,8)+'…'+(device.revoked?' · 已移除':' · 最近上报 '+day(device.lastEventAt));
		line.append(label);
		if(!device.revoked){const button=document.createElement('button');button.type='button';button.textContent='移除';button.addEventListener('click',()=>revokeDevice(device.deviceID));line.append(button);}
		list.append(line);
	}
	if(!member.devices.length)list.textContent='暂无设备';
	details.append(list);
 const remove=document.createElement('button');remove.textContent='停用成员全部设备';remove.type='button';
 remove.addEventListener('click',async()=>{if(!confirm('停用 '+member.memberName+' 的全部设备？历史记录保留。'))return;
 try{await api('members/revoke',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({memberID:member.memberID})});await load();}catch{$('error').hidden=false;$('error').textContent='停用失败，请重试。';}});
 details.append(remove);cell.append(details);return cell;
}
async function revokeDevice(deviceID){
	if(!confirm('移除这台设备？它将立即停止上报；已入账的历史用量保留。'))return;
	try{await api('devices/revoke',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({deviceID})});await load();}
	catch(error){$('error').hidden=false;$('error').textContent=error.status===401?'登录已过期，请重新登录。':'移除失败，请稍后重试。';}
}
$('create-form').addEventListener('submit',async event=>{
	event.preventDefault();const button=event.currentTarget.querySelector('button');button.disabled=true;$('create-error').textContent='';
	try{
		const data=await api('create',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({teamName:$('team-name').value})});
		$('new-team-id').textContent=data.teamID;$('new-invite').textContent=data.inviteCode;$('new-password').textContent=data.loginPassword;
		pendingPassword=data.loginPassword;$('team-name').value='';
		$('entry').hidden=true;$('credentials').hidden=false;$('loading').hidden=true;
	}catch(error){$('create-error').textContent=error.status===429?'创建过于频繁，请 1 小时后再试。':error.status===503?'自助团队尚未在此服务开启。':'创建失败，请稍后重试。';}
	finally{button.disabled=false;}
});
$('open-dashboard').addEventListener('click',async()=>{
    invalidateSession();
	const teamID=$('new-team-id').textContent;
	try{await api('login',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({teamID,password:pendingPassword})});pendingPassword=null;await load();}
	catch{$('credentials').hidden=true;entryView();$('login-error').textContent='自动登录失败，请用团队 ID 和管理密码手动登录。';}
});
$('login-form').addEventListener('submit',async event=>{
    invalidateSession();
	event.preventDefault();const button=event.currentTarget.querySelector('button');button.disabled=true;$('login-error').textContent='';
	try{await api('login',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({teamID:$('team-id').value.trim(),password:$('password').value})});$('password').value='';await load();}
	catch(error){$('login-error').textContent=error.status===429?'尝试过于频繁，请 15 分钟后再试。':error.status===401?'团队 ID 或管理密码不正确。':'登录服务暂不可用，请稍后重试。';}
	finally{button.disabled=false;}
});
$('logout').addEventListener('click',async()=>{entryView();try{await api('logout',{method:'POST'});}catch{}entryView();$('password').value='';});
$('rotate').addEventListener('click',async()=>{
	try{const data=await api('invite/rotate',{method:'POST'});$('rotated-invite').textContent=data.inviteCode;$('rotate-result').hidden=false;await load();}
	catch(error){$('error').hidden=false;$('error').textContent=error.status===401?'登录已过期，请重新登录。':'轮换失败，请稍后重试。';}
});
$('days').addEventListener('change',load);$('refresh').addEventListener('click',load);load();

async function loadQuota(){
 const generation=sessionGeneration;
 try{const data=await api('accounts');if(generation!==sessionGeneration)return;const rows=$('quota-rows');rows.replaceChildren();$('quota-error').textContent='';
  for(const item of data.accounts){const row=document.createElement('tr');for(const text of [item.provider,item.account_name||'未命名',item.model_count,item.sample_count]){const td=document.createElement('td');td.textContent=text;row.append(td);}
   const td=document.createElement('td'),button=document.createElement('button');button.textContent='删除额度历史';button.type='button';button.addEventListener('click',async()=>{
    if(!confirm(`删除本团队 ${item.provider} / ${item.account_name||'未命名'} 的额度历史？成员用量和其他团队不受影响。`))return;
    button.disabled=true;try{await api('accounts?'+new URLSearchParams({provider:item.provider,account_name:item.account_name}),{method:'DELETE'});await loadQuota();}catch{$('quota-error').textContent='删除失败，请刷新或重新登录。';button.disabled=false;}
   });td.append(button);row.append(td);rows.append(row);
  }
 }catch{if(generation===sessionGeneration)$('quota-error').textContent='额度数据暂不可用，请稍后刷新。';}
}
