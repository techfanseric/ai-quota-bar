// Feedback wall: submits to /v1/feedback and renders the published list.
// All rendering uses createElement/textContent; contact info is never part of
// the public API response.
const $=id=>document.getElementById(id);
const PAGE=20;
let loading=false,offset=0;
async function api(path,options={}) {
	const response=await fetch('/v1/feedback'+path,{credentials:'same-origin',...options});
	const data=await response.json().catch(()=>({}));
	if(!response.ok){const error=new Error(data.error||'request_failed');error.status=response.status;throw error;}
	return data;
}
function card(item) {
	const li=document.createElement('li');li.className='feedback-item';
	const head=document.createElement('div');head.className='item-head';
	const name=document.createElement('strong');name.textContent=item.nickname||'匿名用户';
	const meta=document.createElement('span');meta.className='meta';
	const date=new Date(item.createdAt);const time=isNaN(date.getTime())?item.createdAt:date.toLocaleString('zh-CN',{year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit'});
	meta.textContent=(item.source==='app'?'App':'网页')+(item.appVersion?' · v'+item.appVersion:'')+' · '+time;
	head.append(name,meta);
	const message=document.createElement('p');message.textContent=item.message;
	li.append(head,message);
	return li;
}
async function loadWall(reset=true) {
	if(loading)return;loading=true;$('refresh').disabled=true;$('more').disabled=true;
	try{
		const data=await api('?limit='+PAGE+'&offset='+(reset?0:offset));
		if(reset){$('feedback-list').replaceChildren();offset=0;}
		offset+=data.items.length;
		for(const item of data.items)$('feedback-list').append(card(item));
		$('count').textContent=data.total;
		$('wall-empty').hidden=data.total>0;
		$('wall-error').hidden=true;
		$('more').hidden=offset>=data.total;
		$('more').textContent='加载更多（'+offset+'/'+data.total+'）';
	}catch{$('wall-error').hidden=false;}
	finally{loading=false;$('refresh').disabled=false;$('more').disabled=false;}
}
$('feedback-form').addEventListener('submit',async event=>{
	event.preventDefault();const button=event.currentTarget.querySelector('button[type=submit]');
	button.disabled=true;$('submit-error').textContent='';$('submit-success').hidden=true;
	try{
		await api('',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({nickname:$('nickname').value,contact:$('contact').value,message:$('message').value})});
		$('feedback-form').reset();$('submit-success').hidden=false;
		await loadWall(true);
	}catch(error){
		$('submit-error').textContent=error.status===429?'提交过于频繁，请 1 小时后再试。'
			:error.status===413?'留言内容太长了，请精简后重试。'
			:error.status===400?'留言内容不符合要求，请检查后重试。'
			:error.status===503?'反馈服务暂不可用，请稍后重试。'
			:'提交失败，请稍后重试。';
	}finally{button.disabled=false;}
});
$('refresh').addEventListener('click',()=>loadWall(true));
$('more').addEventListener('click',()=>loadWall(false));
loadWall(true);
