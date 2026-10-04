import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync} from 'node:fs';

const flush=async()=>{for(let i=0;i<8;i++)await new Promise(resolve=>setImmediate(resolve));};
const HOUR=3600000;
const p2=n=>String(n).padStart(2,'0');
const md=t=>{const d=new Date(t+8*3600000);return p2(d.getUTCMonth()+1)+'/'+p2(d.getUTCDate());};
// 中文界面按 UTC+8 展示（admin-quota.js 的展示时区）。
const clockOf=t=>{const d=new Date(t+8*3600000);return p2(d.getUTCHours())+':'+p2(d.getUTCMinutes());};
const resetRange=(start,end)=>`${md(start)} ${clockOf(start)}-${clockOf(end)}`;

// Shared vm harness: DOM shim + fetch mock. The console loads the same three
// scripts in admin.html's order — admin-quota.js (renderer), admin-charts.js
// (svg) and admin.js (data). historyStatus forces the history endpoint to fail.
function buildConsole({historyStatus=200,truncated=false,extraItems=[]}={}){
 const NOW=Date.now();
 const iso=t=>new Date(t).toISOString();
 const elements=new Map();
 // 真实 DOM 里，脱离文档的节点 clientWidth 恒为 0；挂进文档后才有宽度。
 // 这里照搬这个语义：图表若画在游离树上，只能退回 296px 兜底宽度。
 const mounted=node=>{for(let n=node;n;n=n.parent)if(n===documentElement)return true;return false;};
 const fakeNode=(tag='div')=>{const node={
  tag,hidden:false,value:'',disabled:false,textContent:'',colSpan:0,type:'',parent:null,
  className:'',children:[],listeners:{},attributes:{},style:{},
  setAttribute(key,value){this.attributes[key]=String(value);},
  append(...nodes){for(const n of nodes){n.parent=this;this.children.push(n);}},
  appendChild(node){node.parent=this;this.children.push(node);return node;},
  add(child){child.parent=this;this.children.push(child);},
  replaceChildren(...nodes){for(const c of this.children)c.parent=null;
   this.children.length=0;this.append(...nodes);},
  remove(){this.removed=true;},addEventListener(event,fn){this.listeners[event]=fn;},
  // 只支持单类选择器（生产代码只用 .qm-model），够覆盖两段式渲染的遍历。
  querySelectorAll(selector){
   const cls=String(selector).replace(/^\./,''),out=[];
   const walk=node=>{for(const child of node.children||[]){
    if((child.className||'').split(' ').includes(cls))out.push(child);
    walk(child);}};
   walk(this);return out;
  }};
  Object.defineProperty(node,'clientWidth',{get(){return mounted(node)?324:0;}});
  return node;};
 const documentElement=fakeNode('html');
 documentElement.lang='zh-CN';
 const element=id=>{if(!elements.has(id)){const n=fakeNode();n.parent=documentElement;elements.set(id,n);}
  return elements.get(id);};
 const codexAccount=extra=>({team_id:'t1',team_name:'Team A',provider:'codex',account_name:'a@example.test',...extra});
 const baseQuotaItems=[
  // Codex：5h 短周期 + Weekly 长周期；detail_text 还原 App 的 plan/source 表达。
  codexAccount({model_id:'5h',model_name:'5h',
   current_interval_total:100,current_interval_remaining:60,weekly_total:100,weekly_remaining:80,value_suffix:'%',
   reset_start_time:iso(NOW-2*HOUR),reset_end_time:iso(NOW+3*HOUR),device_id:'deadbeef1234',
   detail_text:'Pro 20x · OAuth · resets 09/30 12:00',sampled_at:iso(NOW-300000)}),
  codexAccount({model_id:'weekly',model_name:'Weekly',
   current_interval_total:100,current_interval_remaining:45,weekly_total:0,weekly_remaining:0,value_suffix:'%',
   reset_start_time:iso(NOW-2*86400000),reset_end_time:iso(NOW+5*86400000),device_id:'deadbeef1234',
   detail_text:'Pro 20x · OAuth',sampled_at:iso(NOW-300000)}),
  // GLM：计数模式、窗口内、无账号名 —— 默认展开的就是最紧张的这个（28.75%）。
  {team_id:'t2',team_name:'Team B',provider:'glm',account_name:'',model_id:'glm-4.6',model_name:'GLM-4.6',
   current_interval_total:800,current_interval_remaining:230,weekly_total:0,weekly_remaining:0,value_suffix:null,
   reset_start_time:iso(NOW-HOUR),reset_end_time:iso(NOW+4*HOUR),device_id:'cafe12345678',sampled_at:iso(NOW-120000)},
 ];
 // extraItems 让单个用例往默认三行之外再加账号，不必重写整套 fixture。
 const quotaItems=[...baseQuotaItems,...extraItems];
 const sample=(model_id,model_name,offsetMs,remaining,extra={})=>({model_id,model_name,sampled_at:iso(NOW+offsetMs),
  current_interval_total:100,current_interval_remaining:remaining,weekly_total:100,weekly_remaining:80,value_suffix:'%',
  reset_start_time:iso(NOW-2*HOUR),reset_end_time:iso(NOW+3*HOUR),device_id:'deadbeef1234',
  detail_text:'Pro 20x · OAuth',...extra});
 const historySamples=[
  // 上一周期最后一个点（重置已过）→ 进曲线并形成一个已完成周期；
  // Weekly 在窗口内没有样本 → 退回胶囊条 + 天分隔线。
  sample('5h','5h',-95*60000,96,{reset_start_time:iso(NOW-7*HOUR),reset_end_time:iso(NOW-2*HOUR)}),
  sample('5h','5h',-90*60000,90),
  sample('5h','5h',-60*60000,50),
  sample('5h','5h',-30*60000,20),
 ];
 const calls=[];
 const respond=(ok,body,status=200)=>({ok,status,json:async()=>body});
 const context=vm.createContext({Intl,Option:function(text,value){this.text=text;this.value=value;},URLSearchParams,
  document:{documentElement,getElementById:element,
   createElement:tag=>fakeNode(tag),createElementNS:(ns,tag)=>fakeNode(tag)},
  calls,
  fetch:async path=>{
   calls.push(path);
   if(path.includes('data/quota-history')){
    if(historyStatus!==200)return respond(false,{error:'history_unavailable'},historyStatus);
    const query=new URLSearchParams(path.split('?')[1]||'');
    return respond(true,{ok:true,samples:query.get('team_id')==='t1'&&query.get('provider')==='codex'?historySamples:[],
     truncated:truncated,row_budget:5000,hours:Number(query.get('hours')||168),model:query.get('model')||''});
   }
   if(path.includes('overview'))return respond(true,{ok:true,generatedAt:iso(NOW),coverageSince:null,
    metrics:{total:2,dau:1,wau:1,mau:2,new_today:0,reporting_recently:1},
    trend:[{day:'2026-09-27',active:1,newInstalls:1},{day:'2026-09-28',active:1,newInstalls:0}],
    versions:[],systems:[],legacy:{syncedDevices:0,configuredMembers:0}});
   if(path.includes('feedback'))return respond(true,{ok:true,counts:{published:0,hidden:0},items:[]});
   if(path.includes('data/teams'))return respond(true,{ok:true,teams:[{team_id:'t1',team_name:'Team A',members:1,devices:1,events:0},
    {team_id:'t2',team_name:'Team B',members:1,devices:1,events:0}]});
   if(path.includes('data/quota'))return respond(true,{ok:true,items:quotaItems});
   if(path.includes('data/accounts'))return respond(true,{ok:true,accounts:[]});
   if(path.includes('data/legacy'))return respond(true,{ok:true,accounts:[]});
   if(path.includes('data/audit'))return respond(true,{ok:true,items:[]});
   return respond(false,{error:'not_configured'},503);
  }});
 // window is the global object in a browser; mirror that inside the vm.
 vm.runInContext('var window=this;',context);
 for(const file of ['../public/admin-quota.js','../public/admin-charts.js','../public/admin.js'])
  vm.runInContext(readFileSync(new URL(file,import.meta.url),'utf8'),context);
 return {element,calls,historySamples,NOW,quotaItems,api:vm.runInContext('window.AdminQuota',context)};
}
const byClass=(node,className)=>{
 const found=[];
 const walk=current=>{for(const child of current.children||[]){
  if((child.className||'').split(' ').includes(className))found.push(child);
  walk(child);}};
 walk(node);
 return found;
};
const providers=element=>byClass(element('quota-cards'),'qm-provider');
const accountRows=section=>byClass(section,'qm-account');
const accountHead=row=>byClass(row,'qm-account-head')[0];
const byTag=(node,tag)=>(node.children||[]).filter(child=>child.tag===tag);
const svgOf=node=>byClass(node,'qm-plot')[0].children.find(child=>child.tag==='svg');
const cycleRow=node=>{const box=byClass(node,'qm-cycles')[0];
 return box&&box.children.find(child=>(child.className||'')==='cycle-row');};
const modelRows=row=>byClass(row,'qm-model');
const metaRow=row=>byClass(modelRows(row)[0],'qm-meta')[0];

test('console lists providers → accounts → models like the app menu, tightest account open by default',async()=>{
 const {element,NOW}=buildConsole();
 // 首次渲染时默认展开的账号先显示加载态。
 await flush();
 const grid=element('quota-cards');
 assert.equal(byClass(grid,'qm-title')[0].children[0].textContent,'2 Providers · 2 Accounts · 3 Models');
 const sections=providers(element);
 // 供应商按该组最低剩余排序：glm 28.75% 在 codex 45% 之前。
 assert.equal(sections.length,2);
 assert.equal(byClass(sections[0],'qm-provider-name')[0].textContent,'glm');
 assert.equal(byClass(sections[1],'qm-provider-name')[0].textContent,'codex');
 for(const section of sections)assert.equal(byClass(section,'qm-provider-count')[0].textContent,'1/1');
 // 箭头是内联 svg（App 用 SF Symbol，文字三角在 8px 下不可读）。
 assert.equal(byClass(sections[0],'qm-provider-head')[0].children[0].attributes['data-open'],'true');
 // GLM 账号：默认展开（最紧张），未命名账号沿用 App 的英文占位。
 const glmAccount=accountRows(sections[0])[0];
 assert.equal(glmAccount.className,'qm-account is-open');
 assert.equal(byClass(accountHead(glmAccount),'qm-account-name')[0].children[0].textContent,'Unknown account');
 assert.equal(byClass(accountHead(glmAccount),'qm-source')[0].textContent,'Cloud · '+clockOf(NOW-120000));
 assert.equal(byClass(accountHead(glmAccount),'qm-team')[0].textContent,'Team B');
 // 模型行：行头「模型名 —— 剩余」，右侧按 App 的剩余文本口径（计数模式无后缀）。
 const glmModel=modelRows(glmAccount)[0];
 assert.equal(byClass(glmModel,'qm-model-name')[0].textContent,'GLM-4.6');
 const right=byClass(glmModel,'qm-model-right')[0];
 assert.equal(right.textContent,'230');
 assert.equal(right.style.color,'#507a59');
 const capsule=byClass(glmModel,'qm-capsule')[0];
 assert.equal(byClass(capsule,'qm-capsule-fill')[0].style.width,'71.25%');
 assert.equal(byClass(capsule,'qm-capsule-fill')[0].style.background,'#507a59');
 // 节奏偏离 → 胶囊条上出现 PaceTipStripes 标记。
 assert.equal(byClass(capsule,'qm-capsule-pace').length,1);
 const glmMeta=metaRow(glmAccount);
 assert.equal(byClass(glmMeta,'qm-meta-left')[0].textContent,'');
 const pieces=byClass(glmMeta,'qm-meta-right')[0].children.filter(child=>child.className!=='qm-dot');
 assert.equal(pieces.length,2);
 assert.match(pieces[0].textContent,/^(超额|余量) \d+%$/);
 assert.equal(pieces[1].textContent,resetRange(NOW-HOUR,NOW+4*HOUR));
 // Codex 账号：默认折叠，右侧给出「来源 · 时间 · 最低剩余」，不展开也能横向比较。
 const codexSection=providers(element)[1];
 assert.equal(accountRows(codexSection).length,1);
 const codexAccount=accountRows(codexSection)[0];
 assert.equal(accountHead(codexAccount).children[0].attributes['data-open'],'false');
 assert.equal(byClass(accountHead(codexAccount),'qm-account-name')[0].children[0].textContent,'a@example.test');
 assert.equal(byClass(accountHead(codexAccount),'qm-plan')[0].textContent,'· Pro 20x');
 const codexMeta=byClass(accountHead(codexAccount),'qm-account-meta')[0];
 // Codex 的来源来自 detail_text，与 App 的 accountSourceSummary 同源。
 assert.equal(byClass(codexMeta,'qm-source')[0].textContent,'OAuth · '+clockOf(NOW-300000));
 assert.equal(byClass(codexMeta,'qm-worst')[0].textContent,'最低剩余 45%');
 // 45% 剩余仍属健康区间 —— 与 App 的 tint 阈值一致（橙线在 20%）。
 assert.equal(byClass(codexMeta,'qm-worst')[0].style.color,'#507a59');
 assert.equal(modelRows(codexAccount).length,0);
});

test('expanding an account lazily loads its history and draws the app-shaped rows',async()=>{
 const {element,calls,NOW}=buildConsole();
 await flush();
 accountHead(accountRows(providers(element)[1])[0]).listeners.click();
 await flush();
 // 失败的请求也只发一次。
 assert.equal(calls.filter(path=>path.includes('data/quota-history')).length,2);
 // 只有展开的账号取历史，各一次；默认展开的那个也会自动加载。
 assert.deepEqual(calls.filter(path=>path.includes('data/quota-history')),
  ['/v1/admin/data/quota-history?team_id=t2&provider=glm&account=&hours=168',
   '/v1/admin/data/quota-history?team_id=t1&provider=codex&account=a%40example.test&hours=168']);
 const rows=modelRows(accountRows(providers(element)[1])[0]);
 assert.equal(rows.length,2);
 // 菜单排序：5h 短周期在 Weekly 长周期之前。
 assert.equal(byClass(rows[0],'qm-model-name')[0].textContent,'5h');
 assert.equal(byClass(rows[0],'qm-model-right')[0].textContent,'60%');
 assert.equal(byClass(rows[1],'qm-model-name')[0].textContent,'Weekly');
 // 窗口仍在进行 → 真正的面积曲线取代胶囊条（admin-charts.js 真实渲染）。
 const curve=svgOf(rows[0]);
 assert.ok(curve,'5h 渲染曲线');
 assert.equal(curve.attributes.viewBox.split(' ')[3],'84');
 const polyline=byTag(curve,'polyline')[0];
 assert.ok(polyline);
 assert.equal(polyline.attributes.stroke,'#507a59');
 assert.equal(polyline.attributes['stroke-width'],'2');
 // 四个窗口内样本（含上一周期最后一个点）都进曲线，Y 轴按百分比 0-100。
 assert.equal(polyline.attributes.points.split(' ').length,4);
 const plotTop=8,plotBottom=66;
 const ys=polyline.attributes.points.split(' ').map(pair=>Number(pair.split(',')[1]));
 assert.deepEqual(ys.map(y=>Math.round(y)),[96,90,50,20].map(v=>Math.round(plotBottom-v/100*(plotBottom-plotTop))));
 const gradient=byTag(curve,'defs')[0].children[0];
 assert.ok(gradient.children.every(stop=>stop.attributes['stop-color']==='#507a59'));
 // Weekly 没有窗口内样本 → 回到胶囊条 + 周窗口的天分隔线。
 const weeklyPlot=byClass(rows[1],'qm-plot')[0];
 assert.equal(byClass(weeklyPlot,'qm-capsule').length,1);
 assert.ok(byClass(weeklyPlot,'qm-capsule-marker').length>0);
 // 跨周期柱图只收已完成周期（reset 早于当前）。
 // 柱图 = 已完成周期 + 当前进行中的周期（与 App 的 currentCycle 一致），按时间升序。
 const cycles=cycleRow(rows[0]);
 assert.ok(cycles,'5h 有周期柱');
 assert.equal(cycles.children.length,2);
 assert.equal(cycles.children[0].children[0].style.height,'4%');
 assert.equal(cycles.children[0].children[1].textContent,'96');
 assert.equal(cycles.children[1].children[0].style.height,'40%');
 assert.equal(cycles.children[1].children[1].textContent,'60');
 // Weekly 没有已完成周期，但当前周期仍然有一根（App 同样会画 currentCycle）。
 const weeklyCycles=cycleRow(rows[1]);
 assert.equal(weeklyCycles.children.length,1);
 assert.equal(weeklyCycles.children[0].children[0].style.height,'55%');
 assert.equal(weeklyCycles.children[0].children[1].textContent,'45');
 assert.equal(byClass(metaRow(accountRows(providers(element)[1])[0]),'qm-meta-left')[0].textContent,'5 小时周期 · left');
 // 后台补充层与 App 菜单区分开：默认收起，点开才画每小时消耗。
 const extra=byClass(rows[0],'qm-extra')[0];
 const extraToggle=byClass(extra,'qm-toggle')[0];
 assert.equal(extraToggle.textContent,'后台补充 · 每小时消耗 ▸');
 assert.equal(extra.children.length,1);
 extraToggle.listeners.click();
 const opened=byClass(modelRows(accountRows(providers(element)[1])[0])[0],'qm-extra')[0];
 assert.equal(byClass(opened,'qm-toggle')[0].textContent,'后台补充 · 每小时消耗 ▾');
 assert.equal(opened.children.length,2);
 assert.equal(opened.children[1].className,'qm-chart');
 assert.ok(opened.children[1].children.length>0);
});

test('exhausted and full-quota models fold into the app collapsible groups',async()=>{
 const {api,element}=buildConsole();
 await flush();
 api.setItems([
  {team_id:'t2',team_name:'Team B',provider:'glm',account_name:'spent@example.test',model_id:'used',model_name:'Used',
   current_interval_total:100,current_interval_remaining:0,value_suffix:'%',weekly_total:0,weekly_remaining:0,
   sampled_at:new Date().toISOString()},
  {team_id:'t2',team_name:'Team B',provider:'glm',account_name:'spent@example.test',model_id:'fresh',model_name:'Fresh',
   current_interval_total:100,current_interval_remaining:100,value_suffix:'%',weekly_total:0,weekly_remaining:0,
   sampled_at:new Date().toISOString()},
 ]);
 await flush();
 const account=accountRows(providers(element)[0])[0];
 const toggles=byClass(account,'qm-toggle');
 assert.deepEqual(toggles.map(node=>node.textContent),['展开 1 个已用完模型','展开 1 个满额度未使用模型']);
 assert.equal(modelRows(account).length,0);
 toggles[0].listeners.click();
 const expanded=modelRows(accountRows(providers(element)[0])[0]);
 assert.equal(expanded.length,1);
 assert.equal(byClass(expanded[0],'qm-model-name')[0].textContent,'Used');
 assert.equal(byClass(expanded[0],'qm-model-right')[0].style.color,'#9b4a32');
 assert.deepEqual(byClass(accountRows(providers(element)[0])[0],'qm-toggle').map(node=>node.textContent),
  ['收起 1 个已用完模型','展开 1 个满额度未使用模型']);
});

test('team filter, search and expand/collapse all keep the menu structure',async()=>{
 const {api,element,NOW}=buildConsole();
 await flush();
 // 列表视图仍然是原始快照表格。
 assert.equal(element('quota-detail-rows').children.length,3);
 assert.deepEqual(element('quota-detail-rows').children[0].children.map(cell=>cell.textContent),
  ['Team A','codex','a@example.test','5h','60%','80%',
   `${md(NOW-2*HOUR)} ${clockOf(NOW-2*HOUR)} ~ ${md(NOW+3*HOUR)} ${clockOf(NOW+3*HOUR)}`,
   'deadbeef…',`${md(NOW-300000)} ${clockOf(NOW-300000)}`]);
 element('data-team').value='t1';
 element('data-team').listeners.change();
 await flush();
 let sections=providers(element);
 assert.equal(sections.length,1);
 assert.equal(byClass(sections[0],'qm-provider-name')[0].textContent,'codex');
 // 单团队时账号行不再重复团队标签。
 assert.equal(byClass(sections[0],'qm-team').length,0);
 element('data-team').value='';
 element('data-team').listeners.change();
 await flush();
 // 搜索同时命中账号、模型与团队。
 element('qd-search').value='weekly';
 element('qd-search').listeners.input({target:element('qd-search')});
 sections=providers(element);
 assert.equal(byClass(sections[0],'qm-provider-name')[0].textContent,'codex');
 assert.equal(byClass(accountHead(accountRows(sections[0])[0]),'qm-account-name')[0].children[0].textContent,'a@example.test');
 assert.equal(accountRows(sections[0])[0].className,'qm-account is-open');
 element('qd-search').value='nothing-matches';
 element('qd-search').listeners.input({target:element('qd-search')});
 assert.equal(providers(element).length,0);
 assert.equal(element('quota-cards').children[0].className,'empty');
 element('qd-reset-view').listeners.click();
 await flush();
 sections=providers(element);
 assert.equal(sections.length,2);
 // 全部展开后每个账号行都带模型行，全部收起后只剩账号头。
 element('qd-expand-all').listeners.click();
 assert.equal(providers(element).flatMap(accountRows).every(row=>modelRows(row).length>0),true);
 element('qd-collapse-all').listeners.click();
 assert.equal(providers(element).flatMap(accountRows).every(row=>modelRows(row).length===0),true);
 assert.equal(api.state.touched,true);
});

test('each model is a flat side-by-side column, and a view switch re-renders the columns',async()=>{
 const {element}=buildConsole();
 await flush();
 accountHead(accountRows(providers(element)[1])[0]).listeners.click();
 await flush();
 const grid=byClass(accountRows(providers(element)[1])[0],'qm-models')[0];
 // 「每个模型一列」的前提：列是 .qm-models 的直接子元素，彼此平级、不互相嵌套，
 // 交给 CSS grid（auto-fill · 152–200px）横向排布而不是 App 菜单的直列。
 assert.deepEqual(grid.children.map(node=>node.className),['qm-model','qm-model']);
 const before=grid.children[0];
 // 列窄、模型名必然省略，全文挂在 title 上，别让运维靠猜。
 assert.equal(byClass(before,'qm-model-name')[0].attributes.title,'5h');
 // 列表视图下 #quota-cards 是 display:none，图表量不到列宽 ——
 // 切回来必须整块重画，而不是只切换 hidden。
 element('qd-view-list').listeners.click();
 element('qd-view-cards').listeners.click();
 const after=byClass(accountRows(providers(element)[1])[0],'qm-models')[0].children[0];
 assert.notEqual(after,before);
 assert.equal(byClass(after,'qm-model-name')[0].textContent,'5h');
 // 重画不丢交互状态：codex 账号仍是展开的。
 assert.equal(accountRows(providers(element)[1])[0].className,'qm-account is-open');
});

test('charts are drawn only after the column is attached, so no redraw pass is needed',async()=>{
 // 假 DOM 的 clientWidth 跟真实浏览器一致：游离树上恒为 0。
 // 若把画图挪回 modelRow（结构还没进文档），curve() 量到 0，只能退回 296px 兜底
 // 宽度；插入后被 CSS 的 width:100% 拉宽，120ms 后 ResizeObserver 重画又缩回去，
 // 账号卡片高度在两帧之间跳 8px —— 就是线上看到的「每次展开收起都在抖」。
 const {element}=buildConsole();
 await flush();
 accountHead(accountRows(providers(element)[1])[0]).listeners.click();
 await flush();
 const rows=modelRows(accountRows(providers(element)[1])[0]);
 const box=rows[0],plot=byClass(box,'qm-plot')[0];
 // 绘制完成后画图数据被消费，绘图区里是图 + 悬停气泡。
 assert.equal(box._quota,null,'paintModels 之后画图数据被消费');
 assert.equal(plot.children.length,2);
 const curve=plot.children[0];
 assert.equal(curve.tag,'svg');
 assert.equal(curve.attributes.viewBox,'0 0 324 84',
  '必须按挂载后的真实列宽绘制；296 说明画在了游离树上');
 // 收起再展开走同一条路径，宽度依旧稳定。
 accountHead(accountRows(providers(element)[1])[0]).listeners.click();
 await flush();
 accountHead(accountRows(providers(element)[1])[0]).listeners.click();
 await flush();
 const again=modelRows(accountRows(providers(element)[1])[0])[0];
 assert.equal(byClass(again,'qm-plot')[0].children[0].attributes.viewBox,'0 0 324 84');
});

test('history failure keeps the static model rows and shows the retry hint',async()=>{
 const {element,calls}=buildConsole({historyStatus:500});
 await flush();
 accountHead(accountRows(providers(element)[1])[0]).listeners.click();
 await flush();
 // 失败的请求也只发一次。
 assert.equal(calls.filter(path=>path.includes('data/quota-history')).length,2);
 const rows=modelRows(accountRows(providers(element)[1])[0]);
 assert.equal(rows.length,2);
 for(const row of rows)assert.equal(byClass(row,'qm-state')[0].textContent,'历史加载失败，请重试。');
 assert.equal(byClass(rows[0],'qm-plot')[0].children.filter(child=>child.tag==='svg').length,0);
 // 胶囊条兜底：行头剩余数与进度宽度仍然可用。
 const fiveHour=rows[0];
 assert.equal(byClass(fiveHour,'qm-model-right')[0].textContent,'60%');
 assert.equal(byClass(byClass(fiveHour,'qm-capsule')[0],'qm-capsule-fill')[0].style.width,'40%');
});

test('the history window selector re-queries with the chosen range and invalidates the cache',async()=>{
 const {element,calls,api}=buildConsole();
 await flush();
 assert.equal(api.state.hours,168);
 const historyCalls=()=>calls.filter(path=>path.includes('data/quota-history'));
 assert.ok(historyCalls().every(path=>path.includes('hours=168')));
 const before=historyCalls().length;
 // 切到 90 天：缓存整桶作废，展开中的账号按新窗口重新拉。
 api.setHours(2160);
 await flush();
 assert.equal(api.state.hours,2160);
 assert.ok(historyCalls().length>before);
 assert.ok(historyCalls().some(path=>path.includes('hours=2160')));
 // 同一个窗口重复设置不重复打接口。
 const after=historyCalls().length;
 api.setHours(2160);
 await flush();
 assert.equal(historyCalls().length,after);
 // 越界窗口被拒，不会把 hours 写坏。
 api.setHours(99999);
 await flush();
 assert.equal(api.state.hours,2160);
 assert.equal(element('qd-hours').value,'2160');
});

test('an exhausted model hidden in a fold cannot steal the default expansion',async()=>{
 const DAY=86400000,NOW=Date.now(),iso=t=>new Date(t).toISOString();
 const {element}=buildConsole({extraItems:[
  // 这个账号整体最紧张（0%），但 0% 的模型默认折在「已用完」分组里 ——
  // 展开后实际只剩 64% 的 total usage，看起来一片正常。
  {team_id:'t3',team_name:'Team C',provider:'kimi',account_name:'kimi@example.test',model_id:'k2',model_name:'K2',
   current_interval_total:100,current_interval_remaining:0,weekly_total:100,weekly_remaining:12,value_suffix:'%',
   reset_start_time:iso(NOW-5*86400000),reset_end_time:iso(NOW+25*86400000),device_id:'beef12345678',sampled_at:iso(NOW-60000)},
  {team_id:'t3',team_name:'Team C',provider:'kimi',account_name:'kimi@example.test',model_id:'total',model_name:'Total usage',
   current_interval_total:100,current_interval_remaining:64,weekly_total:100,weekly_remaining:64,value_suffix:'%',
   reset_start_time:iso(NOW-5*86400000),reset_end_time:iso(NOW+25*86400000),device_id:'beef12345678',sampled_at:iso(NOW-60000)},
 ]});
 await flush();
 const sections=providers(element);
 // 排序与默认展开都按可见模型：glm 28.75% < codex 45% < kimi 64%。
 assert.deepEqual(sections.map(section=>byClass(section,'qm-provider-name')[0].textContent),['glm','codex','kimi']);
 const kimi=accountRows(sections[2])[0];
 assert.equal(kimi.className,'qm-account');
 // 折叠态的「最低剩余」仍然如实显示 0%，这是状态，不是排序依据。
 assert.equal(byClass(byClass(accountHead(kimi),'qm-account-meta')[0],'qm-worst')[0].textContent,'最低剩余 0%');
 // 真正该被看见的 glm 28.75% 才是默认展开的那个。
 assert.equal(accountRows(sections[0])[0].className,'qm-account is-open');
});

test('a history response over the row budget says so instead of silently looking stale',async()=>{
 const {element}=buildConsole({truncated:true});
 await flush();
 const banner=byClass(element('quota-cards'),'qm-truncated');
 assert.equal(banner.length,1);
 assert.match(banner[0].textContent,/5000/);
 assert.match(banner[0].textContent,/^1 个账号/);
 // 未截断时不占位置。
 const clean=buildConsole();
 await new Promise(resolve=>setImmediate(resolve));
 assert.equal(byClass(clean.element('quota-cards'),'qm-truncated').length,0);
});
