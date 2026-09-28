import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync} from 'node:fs';

const flush=async()=>{for(let i=0;i<6;i++)await new Promise(resolve=>setImmediate(resolve));};

// Shared vm harness: DOM shim + fetch mock. historyStatus lets a test force the
// quota-history endpoint to fail; historySamples feeds the codex account's series.
function buildConsole({historyStatus=200}={}){
 const elements=new Map();
 const fakeNode=()=>({hidden:false,value:'',disabled:false,textContent:'',colSpan:0,children:[],listeners:{},style:{},
  setAttribute(){},append(...nodes){this.children.push(...nodes);},appendChild(node){this.children.push(node);},
  add(child){this.children.push(child);},replaceChildren(){this.children.length=0;},
  addEventListener(event,fn){this.listeners[event]=fn;}});
 const element=id=>{if(!elements.has(id))elements.set(id,fakeNode());return elements.get(id);};
 const quotaItems=[
  {team_id:'t1',team_name:'Team A',provider:'codex',account_name:'a@example.test',model_id:'gpt-5',model_name:'GPT-5',
   current_interval_total:100,current_interval_remaining:60,weekly_total:100,weekly_remaining:80,value_suffix:'%',
   reset_start_time:null,reset_end_time:null,device_id:'deadbeef1234',sampled_at:'2026-09-28T01:02:00Z'},
  {team_id:'t2',team_name:'Team B',provider:'glm',account_name:'',model_id:'glm-4.6',model_name:'GLM-4.6',
   current_interval_total:800,current_interval_remaining:230,weekly_total:0,weekly_remaining:0,value_suffix:null,
   reset_start_time:'2026-09-28T00:00:00Z',reset_end_time:'2026-09-28T05:00:00Z',device_id:'cafe12345678',sampled_at:'2026-09-28T02:00:00Z'},
 ];
 // Codex 168h series (percent mode, ascending): one sample from a previous cycle
 // (reset_end_time null so it yields no cycle bucket) plus three in-window samples
 // of the 2026-09-28T00:00Z~05:00Z window.
 const historySamples=[
  {model_id:'gpt-5',model_name:'GPT-5',sampled_at:'2026-09-27T20:00:00Z',current_interval_total:100,current_interval_remaining:95,
   weekly_total:100,weekly_remaining:80,value_suffix:'%',reset_start_time:'2026-09-27T19:00:00Z',reset_end_time:null,device_id:'deadbeef1234'},
  {model_id:'gpt-5',model_name:'GPT-5',sampled_at:'2026-09-28T01:00:00Z',current_interval_total:100,current_interval_remaining:90,
   weekly_total:100,weekly_remaining:80,value_suffix:'%',reset_start_time:'2026-09-28T00:00:00Z',reset_end_time:'2026-09-28T05:00:00Z',device_id:'deadbeef1234'},
  {model_id:'gpt-5',model_name:'GPT-5',sampled_at:'2026-09-28T02:00:00Z',current_interval_total:100,current_interval_remaining:50,
   weekly_total:100,weekly_remaining:80,value_suffix:'%',reset_start_time:'2026-09-28T00:00:00Z',reset_end_time:'2026-09-28T05:00:00Z',device_id:'deadbeef1234'},
  {model_id:'gpt-5',model_name:'GPT-5',sampled_at:'2026-09-28T03:00:00Z',current_interval_total:100,current_interval_remaining:20,
   weekly_total:100,weekly_remaining:80,value_suffix:'%',reset_start_time:'2026-09-28T00:00:00Z',reset_end_time:'2026-09-28T05:00:00Z',device_id:'deadbeef1234'},
 ];
 const calls=[],chartCalls=[];
 const charts={curve:(c,s)=>{c.children.push({fake:'curve',spec:s});chartCalls.push({fn:'curve',spec:s});},
  cycleBars:(c,s)=>{c.children.push({fake:'cycles',spec:s});chartCalls.push({fn:'cycleBars',spec:s});},
  hourlyBars:(c,s)=>{c.children.push({fake:'hourly',spec:s});chartCalls.push({fn:'hourlyBars',spec:s});}};
 const respond=(ok,body,status=200)=>({ok,status,json:async()=>body});
 const context=vm.createContext({Intl,Option:function(text,value){this.text=text;this.value=value;},URLSearchParams,
  document:{documentElement:{lang:'zh-CN'},getElementById:element,
   createElement:()=>fakeNode(),createElementNS:()=>fakeNode()},
  window:{AdminQuotaCharts:charts},calls,
  fetch:async path=>{
   calls.push(path);
   if(path.includes('data/quota-history')){
    if(historyStatus!==200)return respond(false,{error:'history_unavailable'},historyStatus);
    const query=new URLSearchParams(path.split('?')[1]||'');
    return respond(true,{ok:true,samples:query.get('team_id')==='t1'&&query.get('provider')==='codex'?historySamples:[]});
   }
   if(path.includes('overview'))return respond(true,{ok:true,generatedAt:'2026-09-28T03:00:00Z',coverageSince:null,
    metrics:{total:2,dau:1,wau:1,mau:2,new_today:0,reporting_recently:1},
    trend:[{day:'2026-09-27',active:1,newInstalls:1},{day:'2026-09-28',active:1,newInstalls:0}],
    versions:[],systems:[],legacy:{syncedDevices:0,configuredMembers:0}});
   if(path.includes('feedback'))return respond(true,{ok:true,counts:{published:0,hidden:0},items:[]});
   if(path.includes('data/teams'))return respond(true,{ok:true,teams:[{team_id:'t1',team_name:'Team A',members:1,devices:1,events:0},{team_id:'t2',team_name:'Team B',members:1,devices:1,events:0}]});
   if(path.includes('data/quota'))return respond(true,{ok:true,items:quotaItems});
   if(path.includes('data/accounts'))return respond(true,{ok:true,accounts:[]});
   if(path.includes('data/legacy'))return respond(true,{ok:true,accounts:[]});
   if(path.includes('data/audit'))return respond(true,{ok:true,items:[]});
   return respond(false,{error:'not_configured'},503);
  }});
 vm.runInContext(readFileSync(new URL('../public/admin.js',import.meta.url),'utf8'),context);
 return {element,calls,chartCalls,historySamples};
}

test('admin console renders every account quota detail and filters by the selected team',async()=>{
 const {element,calls,chartCalls}=buildConsole();
 await flush();
 const rows=element('quota-detail-rows').children;
 assert.equal(rows.length,2);
 assert.deepEqual(rows[0].children.map(cell=>cell.textContent),
  ['Team A','codex','a@example.test','GPT-5','60%','80%','—','deadbeef…','2026-09-28 01:02']);
 assert.deepEqual(rows[1].children.map(cell=>cell.textContent),
  ['Team B','glm','未命名','GLM-4.6','230 / 800','—','2026-09-28 00:00 ~ 2026-09-28 05:00','cafe1234…','2026-09-28 02:00']);
 element('data-team').value='t1';
 element('data-team').listeners.change();
 assert.equal(element('quota-detail-rows').children.length,1);
 assert.equal(element('quota-detail-rows').children[0].children[0].textContent,'Team A');
 element('data-team').value='';
 element('data-team').listeners.change();
 await flush();
 const cards=()=>element('quota-cards').children;
 assert.equal(cards().length,2);
 const worstFirst=cards()[0],urgentSecond=cards()[1];
 assert.equal(worstFirst.children[0].children[1].textContent,'glm');
 assert.equal(worstFirst.children[0].children[2].textContent,'未命名');
 assert.equal(worstFirst.children[0].children[3].textContent,'Team B');
 assert.equal(worstFirst.children[1].textContent,'1 个模型 · 最低剩余 29%');
 assert.equal(urgentSecond.children[0].children[1].textContent,'codex');
 assert.equal(urgentSecond.children[0].children[2].textContent,'a@example.test');
 assert.equal(urgentSecond.children[1].textContent,'1 个模型 · 最低剩余 60%');
 assert.equal(worstFirst.children.length,2);
 assert.equal(urgentSecond.children.length,2);
 worstFirst.children[0].listeners.click();
 urgentSecond.children[0].listeners.click();
 const openCards=()=>element('quota-cards').children;
 assert.equal(openCards().length,2);
 assert.equal(openCards()[0].children.length,3);
 assert.equal(openCards()[1].children.length,3);
 const glmRow=openCards()[0].children[2].children[0];
 assert.equal(glmRow.children[0].children[0].textContent,'GLM-4.6');
 assert.equal(glmRow.children[0].children[1].textContent,'230 / 800');
 assert.equal(glmRow.children[1].children[0].style.width,'71.25%');
 assert.equal(glmRow.children[1].children[0].style.background,'#507a59');
 assert.equal(glmRow.children[2].children[0].textContent,'重置 09-28 00:00 ~ 09-28 05:00');
 assert.equal(glmRow.children[2].children[2].textContent,'设备 cafe1234…');
 const codexRow=openCards()[1].children[2].children[0];
 assert.equal(codexRow.children[0].children[1].textContent,'60%');
 assert.equal(codexRow.children[1].children[0].style.width,'40%');
 assert.equal(codexRow.children[2].children[0].textContent,'周 80%');
 // While the history fetch is in flight both expanded models show the loading state.
 assert.equal(glmRow.children[3].className,'qd-state');
 assert.equal(glmRow.children[3].textContent,'历史加载中…');
 assert.equal(codexRow.children[3].textContent,'历史加载中…');
 await flush();
 // One history fetch per opened account, cached (no refetch on re-render).
 const historyCalls=calls.filter(path=>path.includes('data/quota-history'));
 assert.equal(historyCalls.length,2);
 assert.ok(calls.includes('/v1/admin/data/quota-history?team_id=t1&provider=codex&account=a%40example.test&hours=168'));
 assert.ok(calls.includes('/v1/admin/data/quota-history?team_id=t2&provider=glm&account=&hours=168'));
 // Multi-open preserved: both cards keep their expanded bodies after the re-render.
 assert.equal(openCards().length,2);
 assert.equal(openCards()[0].children.length,3);
 assert.equal(openCards()[1].children.length,3);
 // GLM account has no history samples: static rows stay, plus the empty-history state.
 const glmBox=openCards()[0].children[2].children[0];
 assert.equal(glmBox.children[0].children[0].textContent,'GLM-4.6');
 assert.equal(glmBox.children[1].children[0].style.width,'71.25%');
 assert.equal(glmBox.children[2].children[0].textContent,'重置 09-28 00:00 ~ 09-28 05:00');
 assert.ok(!glmBox.children.some(node=>node.className==='qd-chart'));
 assert.equal(glmBox.children[3].className,'qd-state');
 assert.equal(glmBox.children[3].textContent,'近 7 天没有上报样本。');
 // Codex account got samples: static rows stay and the curve is drawn.
 const codexBox=openCards()[1].children[2].children[0];
 assert.equal(codexBox.children[0].children[1].textContent,'60%');
 assert.equal(codexBox.children[1].children[0].style.width,'40%');
 const curveCalls=chartCalls.filter(call=>call.fn==='curve');
 assert.equal(curveCalls.length,1);
 const curveSpec=curveCalls[0].spec;
 // Points come from the vm realm: project to host arrays of primitives via the
 // host Array.from so deepEqual compares same-realm values.
 assert.deepEqual(Array.from(curveSpec.points,point=>[point.t,point.y]),[
  [Date.parse('2026-09-28T01:00:00Z'),90],
  [Date.parse('2026-09-28T02:00:00Z'),50],
  [Date.parse('2026-09-28T03:00:00Z'),20]]);
 assert.equal(curveSpec.windowStart,Date.parse('2026-09-28T00:00:00Z'));
 assert.equal(curveSpec.windowEnd,Date.parse('2026-09-28T05:00:00Z'));
 assert.equal(curveSpec.tint,'#507a59');
 assert.ok(curveSpec.pace&&Number.isFinite(curveSpec.pace.expectedUsedPercent)&&typeof curveSpec.pace.reserve==='boolean');
 assert.ok(codexBox.children.some(node=>node.className==='qd-chart'));
 // Pace label: derived from the spy-recorded pace so the assertion is clock-independent.
 const delta=100-curveSpec.points.at(-1).y-curveSpec.pace.expectedUsedPercent;
 const value=Math.round(Math.abs(delta));
 // Mirrors T.paceLabel precedence: the rounded value ≤ 2 always reads 节奏正常.
 const expectedPace=value<=2?'节奏正常':delta>2?`超额 ${value}%`:`余量 ${value}%`;
 const metaSpans=codexBox.children[2].children.map(node=>node.textContent);
 assert.equal(metaSpans[0],expectedPace);
 assert.ok(/节奏正常|超额|余量/.test(metaSpans[0]));
 assert.equal(codexBox.children[2].children[0].style.color,delta>2?'#9b4a32':'#69746c');
 assert.ok(metaSpans.includes('周 80%'));
 assert.ok(metaSpans.includes('设备 deadbeef…'));
 assert.ok(metaSpans.includes('上报 09-28 01:02'));
 // Hourly consumption mini bars are non-empty; at most one completed cycle exists.
 const hourlyCalls=chartCalls.filter(call=>call.fn==='hourlyBars');
 assert.equal(hourlyCalls.length,1);
 assert.ok(hourlyCalls[0].spec.buckets.length>0);
 assert.ok(hourlyCalls[0].spec.buckets.every(bucket=>bucket.consumedPercent>=0));
 const miniRows=codexBox.children.find(node=>node.className==='qd-mini-rows');
 assert.ok(miniRows);
 assert.ok(miniRows.children.some(half=>half.children.some(node=>node.className==='qd-mini-label'&&node.textContent==='每小时消耗')));
 const cycleCalls=chartCalls.filter(call=>call.fn==='cycleBars');
 assert.ok(cycleCalls.length===0||cycleCalls[0].spec.cycles.length<=1);
 if(cycleCalls.length===1)assert.ok(cycleCalls[0].spec.cycles.every(cycle=>cycle.resetsAt<=Date.now()));
 element('qd-view-list').listeners.click();
 assert.equal(element('quota-cards').hidden,true);
 assert.equal(element('quota-table-wrap').hidden,false);
 assert.equal(element('quota-detail-rows').children.length,2);
 element('qd-view-cards').listeners.click();
 assert.equal(element('quota-cards').hidden,false);
 assert.equal(element('quota-cards').children.length,2);
});

test('quota history failure keeps the static model rows and shows the retry hint',async()=>{
 const {element,calls}=buildConsole({historyStatus:500});
 await flush();
 element('data-team').value='';
 element('data-team').listeners.change();
 await flush();
 const cards=element('quota-cards').children;
 assert.equal(cards.length,2);
 const heads=cards.map(card=>card.children[0]);
 heads[0].listeners.click();heads[1].listeners.click();
 await flush();
 const openCards=element('quota-cards').children;
 assert.equal(openCards.length,2);
 assert.ok(calls.filter(path=>path.includes('data/quota-history')).length===2);
 // Static head/bar/meta survive the failed fetch; only the state hint is appended.
 assert.equal(openCards[0].children.length,3);
 assert.equal(openCards[1].children.length,3);
 const glmBox=openCards[0].children[2].children[0];
 assert.equal(glmBox.children[0].children[1].textContent,'230 / 800');
 assert.equal(glmBox.children[1].children[0].style.width,'71.25%');
 assert.equal(glmBox.children[2].children[0].textContent,'重置 09-28 00:00 ~ 09-28 05:00');
 assert.equal(glmBox.children[3].className,'qd-state');
 assert.equal(glmBox.children[3].textContent,'历史加载失败，请重试。');
 const codexBox=openCards[1].children[2].children[0];
 assert.equal(codexBox.children[1].children[0].style.width,'40%');
 assert.equal(codexBox.children[2].children[0].textContent,'周 80%');
 assert.equal(codexBox.children[3].textContent,'历史加载失败，请重试。');
});
