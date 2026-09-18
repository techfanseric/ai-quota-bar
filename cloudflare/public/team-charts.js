// Actual team aggregates only. This module never reads the landing-page fixtures.
window.TeamCharts=(()=>{
 const en=()=>document.documentElement.lang.startsWith('en'),t=(zh,english)=>en()?english:zh;
 let root,overview,api,valid,serial=0,metric='tokens',member='',device='',account='',selectedDate='',daily=[],hourly=[],asOf;
 const el=(tag,text,className)=>{const node=document.createElement(tag);if(text!=null)node.textContent=text;if(className)node.className=className;return node;};
 const $=id=>document.getElementById(id),fmt=n=>new Intl.NumberFormat(en()?'en-US':'zh-CN',{maximumFractionDigits:1}).format(n);
 const zero=()=>({records:0,input:0,output:0,cached:0,cacheWrite:0,reasoning:0,pricedRecords:0,costUSD:0,estimatedRecords:0});
 const total=rows=>{const r=zero();for(const row of rows)for(const key of Object.keys(r))r[key]+=Number(row[key]||0);r.cacheHitRate=r.input?r.cached/r.input:null;return r;};
 const value=row=>metric==='tokens'?row.input+row.output:metric==='records'?row.records:metric==='cache'?(row.input?row.cached/row.input*100:null):(row.pricedRecords===row.records?row.costUSD:null);
 const formatted=row=>{const n=value(row);return n==null?t('未定价 / 无数据','Unpriced / no data'):metric==='cache'?n.toFixed(1)+'%':metric==='cost'?'$'+n.toFixed(4):fmt(n);};
 const timestamp=date=>new Date(date).toISOString().slice(0,16).replace('T',' ')+' UTC';
 function expanded(response){const start=Date.parse(response.from),size=response.bucketSeconds*1000,values=new Map(response.groups.map(row=>[Number(row.id),row]));return Array.from({length:Math.ceil((Date.parse(response.to)-start)/size)},(_,i)=>({...zero(),...values.get(i),start:start+i*size,end:Math.min(Date.parse(response.to),start+(i+1)*size)}));}
 function detail(row){return `${timestamp(row.start)} – ${timestamp(row.end)} · ${fmt(row.input+row.output)} tokens · ${row.records} ${t('条记录','records')} · ${t('输入','Input')} ${fmt(row.input)} · ${t('输出','Output')} ${fmt(row.output)} · ${t('缓存读取','Cached')} ${fmt(row.cached)} · ${t('推理','Reasoning')} ${fmt(row.reasoning)} · ${t('价格覆盖','Price coverage')} ${row.pricedRecords}/${row.records} · ${t('缓存命中','Cache hit')} ${row.input?(row.cached/row.input*100).toFixed(1)+'%':'—'} · ${t('成本','Cost')} ${row.pricedRecords===row.records?'$'+row.costUSD.toFixed(4):t('未完整定价','Not fully priced')}`;}
 function button(text,action,className){const node=el('button',text,className);node.type='button';node.addEventListener('click',action);return node;}
 function selector(id,label,onChange){const wrap=el('label',label),select=el('select');select.id=id;select.addEventListener('change',()=>onChange(select.value));wrap.append(select);return wrap;}
 function options(id,rows,all,selected){const node=$(id);node.replaceChildren();for(const row of [{id:'',name:all},...rows]){const option=el('option',row.name);option.value=row.id;node.append(option);}node.value=selected;}
 function init(){
  root=$('team-charts');if(!root)return;
  root.replaceChildren();root.append(el('h2',t('谁用了多少','Who used how much')));
  const tabs=el('div',null,'chart-tabs');tabs.setAttribute('aria-label',t('统计指标','Usage metric'));
  for(const [id,zh,english] of [['tokens','Tokens','Tokens'],['records','记录数','Records'],['cache','缓存命中','Cache hit'],['cost','估算成本','Est. cost']]){const b=button(t(zh,english),()=>{metric=id;render();});b.dataset.metric=id;tabs.append(b);}root.append(tabs);
  const ranking=el('div',null,'member-ranking');ranking.id='member-ranking';root.append(ranking);
  root.append(el('p',t('点击成员进入细节；上方范围控制成员对比。','Select a member for details. The range above controls this comparison.'),'muted'));
  const filters=el('div',null,'chart-filters');
  filters.append(selector('chart-member',t('成员','Member'),v=>{member=v;device='';fillFilters();fetchCharts();}),selector('chart-device',t('设备','Device'),v=>{device=v;fetchCharts();}),selector('chart-account',t('账号','Account'),v=>{account=v;fetchCharts();}));
  const label=el('label',t('指定日期（UTC）','Inspect date (UTC)')),date=el('input');date.type='date';date.id='chart-date';date.max=new Date().toISOString().slice(0,10);date.addEventListener('change',()=>{selectedDate=date.value;fetchCharts();});label.append(date);filters.append(label,button(t('最近 24 小时','Last 24 hours'),()=>{selectedDate='';date.value='';fetchCharts();}));root.append(filters);
  const status=el('p',null,'muted');status.id='chart-status';status.setAttribute('role','status');root.append(status);
  const plots=el('div',null,'activity-plots');plots.id='activity-plots';root.append(plots);
  const totals=el('div',null,'chart-totals');totals.id='chart-totals';root.append(totals);
  const inspect=el('p',t('悬停、聚焦或点击格子查看精确数值。','Hover, focus or select a cell for exact values.'),'chart-inspect');inspect.id='chart-inspect';inspect.setAttribute('aria-live','polite');root.append(inspect);
  root.append(el('p',t('UTC 时间 · 仅已上报数据；未上报不代表零消耗。每格 5 分钟，输入已含缓存，输出已含推理。成本按配置价格估算，不是供应商账单。','UTC · Reported usage only; missing reports do not imply zero consumption. Each cell is 5 minutes. Input includes cache; output includes reasoning. Cost uses configured prices, not provider bills.'),'muted'));
 }
 function fillFilters(){
  options('chart-member',overview.members.map(m=>({id:m.memberID,name:m.memberName})),t('整个团队','Whole team'),member);
  const devices=overview.members.filter(m=>!member||member===m.memberID).flatMap(m=>m.devices.map(d=>({id:d.deviceID,name:m.memberName+' · '+d.deviceID.slice(0,12)})));
  options('chart-device',devices,t('全部设备','All devices'),device);
  options('chart-account',overview.usage.account.map(a=>({id:a.id,name:a.id==='unknown'?t('账号未知','Unknown account'):a.id})),t('全部账号','All accounts'),account);
 }
 function ranking(){
  const byID=new Map(overview.usage.member.map(row=>[row.memberID,row]));
  const rows=overview.members.map(m=>({...zero(),...byID.get(m.memberID),memberID:m.memberID,name:m.memberName})).sort((a,b)=>(value(b)??-1)-(value(a)??-1));
  const max=metric==='cache'?100:Math.max(1,...rows.map(r=>value(r)||0)),sum=rows.reduce((s,r)=>s+(value(r)||0),0),container=$('member-ranking');container.replaceChildren();
  for(const row of rows){const b=button('',()=>{member=row.memberID;device='';fillFilters();fetchCharts();},'member-bar');b.setAttribute('aria-pressed',String(member===row.memberID));const track=el('span',null,'member-bar-track'),fill=el('span');fill.style.width=(Math.max(0,value(row)||0)/max*100)+'%';track.append(fill);b.append(el('span',row.name,'member-bar-name'),track,el('strong',formatted(row)),el('span',metric!=='cache'&&sum&&value(row)!=null?((value(row)/sum)*100).toFixed(1)+'%':'','member-share'));container.append(b);}
  if(!rows.length)container.append(el('p',t('还没有成员。','No members yet.'),'muted'));
 }
 function cell(row,max,isDay){
  const n=value(row),b=button('',()=>{inspect();if(isDay){selectedDate=new Date(row.start).toISOString().slice(0,10);$('chart-date').value=selectedDate;fetchCharts();}},'activity-cell');
  b.title=detail(row);b.setAttribute('aria-label',b.title);b.disabled=row.start>asOf;if(isDay)b.setAttribute('aria-pressed',String(selectedDate===new Date(row.start).toISOString().slice(0,10)));
  b.dataset.level=n==null?'unknown':n<=0?'0':String(Math.max(1,Math.min(4,Math.ceil(n/Math.max(1,max)*4))));
  const inspect=()=>{$('chart-inspect').textContent=detail(row);};b.addEventListener('mouseenter',inspect);b.addEventListener('focus',inspect);return b;
 }
 function render(){
  if(!root||!overview)return;
  for(const b of root.querySelectorAll('[data-metric]'))b.setAttribute('aria-pressed',String(b.dataset.metric===metric));ranking();
  const plots=$('activity-plots');plots.replaceChildren();if(!daily.length)return;
  const month=el('div'),monthLabel=new Date(daily[0].start).toISOString().slice(0,7);month.append(el('h3',monthLabel+' · '+t('每日','Daily')));
  const calendar=el('div',null,'activity-calendar'),offset=new Date(daily[0].start).getUTCDay(),maxDay=metric==='cache'?100:Math.max(1,...daily.map(r=>value(r)||0));
  for(let i=0;i<offset;i++)calendar.append(el('span'));
  for(const row of daily){const c=cell(row,maxDay,true);c.textContent=new Date(row.start).getUTCDate();calendar.append(c);}month.append(calendar);plots.append(month);
  const hours=el('div',null,'activity-hours-wrap');hours.append(el('h3',(selectedDate||t('最近 24 小时','Last 24 hours'))+' · '+t('每格 5 分钟','5 min / cell')));
  const grid=el('div',null,'activity-hours'),maxHour=metric==='cache'?100:Math.max(1,...hourly.map(r=>value(r)||0));
  for(let hour=0;hour<24;hour++){const column=el('div',null,'activity-hour');for(const row of hourly.slice(hour*12,hour*12+12))column.append(cell(row,maxHour,false));column.append(el('span',hour%2===0?new Date(hourly[hour*12].start).toISOString().slice(11,13):'','hour-label'));grid.append(column);}hours.append(grid);plots.append(hours);
  const monthTotal=total(daily),hourTotal=total(hourly),totals=$('chart-totals');totals.replaceChildren();
  for(const [name,number] of [[monthLabel,formatted(monthTotal)],[selectedDate||t('近 24h','Last 24h'),formatted(hourTotal)],[t('本月输入 / 输出','Month input / output'),fmt(monthTotal.input)+' / '+fmt(monthTotal.output)],[t('定价覆盖','Price coverage'),monthTotal.pricedRecords+'/'+monthTotal.records]]){const item=el('div');item.append(el('span',name),el('strong',number));totals.append(item);}
 }
 async function fetchCharts(){
  const generation=++serial,current=valid;daily=[];hourly=[];render();$('chart-totals').replaceChildren();$('chart-inspect').textContent='';$('chart-status').textContent=t('加载图表…','Loading charts…');
  const now=new Date();asOf=now.getTime();const chosen=selectedDate?new Date(selectedDate+'T00:00:00Z'):now;
  const monthStart=new Date(Date.UTC(chosen.getUTCFullYear(),chosen.getUTCMonth(),1)),monthEnd=new Date(Date.UTC(chosen.getUTCFullYear(),chosen.getUTCMonth()+1,1)),start=selectedDate?chosen:new Date(asOf-86400000),end=selectedDate?new Date(start.getTime()+86400000):now;
  const query=(from,to,seconds)=>{const p=new URLSearchParams({from:from.toISOString(),to:to.toISOString(),bucket_seconds:seconds});if(member)p.set('member_id',member);if(device)p.set('device_id',device);if(account)p.set('account_id',account);return 'timeline?'+p;};
  try{const [d,h]=await Promise.all([api(query(monthStart,monthEnd,86400)),api(query(start,end,300))]);if(generation!==serial||!current())return;daily=expanded(d);hourly=expanded(h);render();$('chart-status').textContent=t('更新于 ','Updated ')+timestamp(asOf);}
  catch(error){if(generation!==serial||!current())return;$('chart-status').textContent=error.status===401||error.status===409?t('团队登录已变化，请从 App 重新打开。','Team sign-in changed. Reopen from the app.'):t('图表加载失败，请点击刷新重试。','Charts could not load. Refresh to retry.');}
 }
 return {update(data,request,isCurrent){overview=data;api=request;valid=isCurrent;if(!root)init();if(!root)return;if(member&&!data.members.some(m=>m.memberID===member)){member='';device='';}fillFilters();fetchCharts();},invalidate(){serial++;member='';device='';account='';selectedDate='';daily=[];hourly=[];if(root){root.replaceChildren();root=null;}}};
})();
