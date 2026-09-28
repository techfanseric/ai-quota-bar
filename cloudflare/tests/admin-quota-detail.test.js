import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync} from 'node:fs';

test('admin console renders every account quota detail and filters by the selected team',async()=>{
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
 const respond=(ok,body,status=200)=>({ok,status,json:async()=>body});
 const context=vm.createContext({Intl,Option:function(text,value){this.text=text;this.value=value;},URLSearchParams,
  document:{documentElement:{lang:'zh-CN'},getElementById:element,
   createElement:()=>fakeNode(),createElementNS:()=>fakeNode()},
  fetch:async path=>{
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
 const flush=async()=>{for(let i=0;i<6;i++)await new Promise(resolve=>setImmediate(resolve));};
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
 element('qd-view-list').listeners.click();
 assert.equal(element('quota-cards').hidden,true);
 assert.equal(element('quota-table-wrap').hidden,false);
 assert.equal(element('quota-detail-rows').children.length,2);
 element('qd-view-cards').listeners.click();
 assert.equal(element('quota-cards').hidden,false);
 assert.equal(element('quota-cards').children.length,2);
});
