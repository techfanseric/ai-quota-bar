import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync} from 'node:fs';

const source=readFileSync(new URL('../public/admin-charts.js',import.meta.url),'utf8');
const fakeNode=tag=>({tag,attributes:{},children:[],style:{},textContent:'',clientWidth:0,
 setAttribute(key,value){this.attributes[key]=String(value);},
 append(...nodes){this.children.push(...nodes);},
 appendChild(node){this.children.push(node);return node;}});
const setup=lang=>{
 const ctx=vm.createContext({document:{documentElement:{lang},
  createElement:tag=>fakeNode(tag),createElementNS:(ns,tag)=>fakeNode(tag)}});
 vm.runInContext('var window=this;',ctx);
 vm.runInContext(source,ctx);
 return vm.runInContext('window.AdminQuotaCharts',ctx);
};
const byTag=(node,tag)=>node.children.filter(child=>child.tag===tag);
const gridTicks=chart=>byTag(chart,'line').filter(node=>node.attributes['stroke-dasharray']==='2,3');

test('curve() draws background, axes, hourly grid, pace guide, gradient area, line and dots',()=>{
 const api=setup('zh-CN');
 const container=fakeNode();container.clientWidth=320;
 const start=Date.UTC(2026,8,28,0,0,0),end=Date.UTC(2026,8,28,5,0,0);
 const chart=api.curve(container,{points:[{t:start+1800000,y:87.5},{t:start+9000000,y:55},{t:start+18000000,y:120}],
  windowStart:start,windowEnd:end,tint:'#507a59',pace:{expectedUsedPercent:41.2,reserve:true}});
 assert.equal(chart,container.children[0]);
 assert.equal(chart.attributes.viewBox,'0 0 320 96');
 assert.equal(chart.attributes.width,'320');
 assert.equal(chart.attributes.height,'96');
 const rects=byTag(chart,'rect');
 assert.equal(rects.length,1);
 assert.equal(rects[0].attributes.rx,'7');
 assert.equal(rects[0].attributes.fill,'rgba(0,0,0,0.035)');
 const lines=byTag(chart,'line');
 assert.equal(lines.filter(node=>node.attributes.stroke==='rgba(0,0,0,0.14)').length,2);
 const grid=gridTicks(chart);
 assert.equal(grid.length,4);
 for(const tick of grid){
  assert.equal(tick.attributes.stroke,'rgba(0,0,0,0.10)');
  assert.equal(tick.attributes.x1,tick.attributes.x2);
 }
 const pace=lines.find(node=>node.attributes['stroke-dasharray']==='3,3');
 assert.ok(pace,'pace guide line');
 assert.equal(pace.attributes.stroke,'#507a59');
 assert.equal(pace.attributes['stroke-opacity'],'0.55');
 assert.equal(pace.attributes.x1,'30');
 assert.equal(pace.attributes.y1,'8');
 assert.equal(pace.attributes.x2,'312');
 assert.equal(pace.attributes.y2,'78');
 assert.deepEqual(byTag(chart,'text').map(node=>node.textContent),['100%','0','00:00','05:00']);
 const defs=byTag(chart,'defs');
 assert.equal(defs.length,1);
 const gradient=defs[0].children[0];
 assert.equal(gradient.tag,'linearGradient');
 assert.match(gradient.attributes.id,/^aqb-grad-/);
 assert.deepEqual(gradient.children.map(stop=>stop.attributes['stop-opacity']),['0.22','0.03']);
 assert.ok(gradient.children.every(stop=>stop.attributes['stop-color']==='#507a59'));
 const paths=byTag(chart,'path');
 assert.equal(paths.length,1);
 assert.equal(paths[0].attributes.fill,`url(#${gradient.attributes.id})`);
 assert.match(paths[0].attributes.d,/L 312 78 L 58\.2 78 Z$/);
 const polylines=byTag(chart,'polyline');
 assert.equal(polylines.length,1);
 assert.equal(polylines[0].attributes['stroke-width'],'2');
 assert.deepEqual(polylines[0].attributes.points.split(' '),['58.2,16.75','171,39.5','312,8']);
 const dots=byTag(chart,'circle');
 assert.equal(dots.length,3);
 assert.ok(dots.every(point=>point.attributes.r==='2'&&point.attributes.fill==='#507a59'));
 assert.equal(dots[2].attributes.cy,'8');
});

test('curve() with a single point draws one dot plus a vertical guide and no polyline',()=>{
 const api=setup('zh-CN');
 const container=fakeNode();
 const start=Date.UTC(2026,8,28,0,0,0);
 const chart=api.curve(container,{points:[{t:start+9000000,y:42}],
  windowStart:start,windowEnd:start+18000000,tint:'#507a59'});
 assert.equal(chart.attributes.viewBox,'0 0 320 96');
 assert.equal(byTag(chart,'polyline').length,0);
 assert.equal(byTag(chart,'path').length,0);
 const dots=byTag(chart,'circle');
 assert.equal(dots.length,1);
 assert.equal(dots[0].attributes.r,'3');
 const guides=byTag(chart,'line').filter(node=>node.attributes['stroke-opacity']==='0.45');
 assert.equal(guides.length,1);
 assert.equal(guides[0].attributes.stroke,'#507a59');
 assert.equal(guides[0].attributes['stroke-width'],'2');
});

test('curve() switches the grid to UTC midnights for multi-day windows and drops it past 8 days',()=>{
 const api=setup('zh-CN');
 const container=fakeNode();container.clientWidth=320;
 const start=Date.UTC(2026,8,28,0,0,0),end=Date.UTC(2026,9,1,0,0,0);
 const chart=api.curve(container,{points:[{t:start+36000000,y:60},{t:end-36000000,y:20}],
  windowStart:start,windowEnd:end,tint:'#507a59'});
 assert.equal(gridTicks(chart).length,2);
 const long=api.curve(container,{points:[{t:Date.UTC(2026,0,2),y:50}],
  windowStart:Date.UTC(2026,0,1),windowEnd:Date.UTC(2026,3,1),tint:'#507a59'});
 assert.equal(gridTicks(long).length,0);
});

test('cycleBars() sorts cycles ascending, sizes bars by peak and grays out full cycles',()=>{
 const api=setup('zh-CN');
 const container=fakeNode();
 const base=Date.UTC(2026,8,28,3,0,0);
 const cycles=[{resetsAt:base+10800000,peakPercent:10},{resetsAt:base+7200000,peakPercent:85},
  {resetsAt:base+3600000,peakPercent:40},{resetsAt:base,peakPercent:100}];
 api.cycleBars(container,{cycles,tint:'#507a59'});
 assert.equal(container.children.length,1);
 const row=container.children[0];
 assert.equal(row.style.display,'flex');
 assert.equal(row.style.alignItems,'flex-end');
 assert.equal(row.style.gap,'2px');
 assert.equal(row.style.height,'30px');
 assert.equal(row.style.marginTop,'6px');
 assert.equal(row.children.length,4);
 assert.deepEqual(row.children.map(bar=>bar.style.height),['100%','40%','85%','10%']);
 assert.deepEqual(row.children.map(bar=>bar.style.background),['#8a948d','#507a59','#507a59','#507a59']);
 assert.ok(row.children.every(bar=>bar.style.flex==='1'&&bar.style.maxWidth==='10px'
  &&bar.style.minWidth==='3px'&&bar.style.borderRadius==='1.5px'));
 assert.deepEqual(row.children.map(bar=>bar.children[0].textContent),
  ['09/28 03:00 · 剩 0%','09/28 04:00 · 剩 60%','09/28 05:00 · 剩 15%','09/28 06:00 · 剩 90%']);
 assert.equal(row.children[0].attributes.title,'09/28 03:00 · 剩 0%');
 const labelled=fakeNode();
 api.cycleBars(labelled,{cycles:[cycles[0]],tint:'#507a59',label:cycle=>'custom '+cycle.peakPercent});
 assert.equal(labelled.children[0].children[0].children[0].textContent,'custom 10');
});

test('hourlyBars() renders per-hour bars with thresholds and a first/last label line',()=>{
 const api=setup('zh-CN');
 const container=fakeNode();
 const base=Date.UTC(2026,8,28,3,0,0);
 api.hourlyBars(container,{buckets:[{hourStart:base+7200000,consumedPercent:60},
  {hourStart:base,consumedPercent:30},{hourStart:base+3600000,consumedPercent:85}]});
 assert.equal(container.children.length,2);
 const row=container.children[0];
 assert.equal(row.children.length,3);
 assert.deepEqual(row.children.map(bar=>bar.style.height),['30%','85%','60%']);
 assert.deepEqual(row.children.map(bar=>bar.style.background),['#507a59','#b07a2a','#507a59']);
 assert.deepEqual(row.children.map(bar=>bar.children[0].textContent),
  ['09/28 03:00 · 耗 30%','09/28 04:00 · 耗 85%','09/28 05:00 · 耗 60%']);
 const labels=container.children[1];
 assert.equal(labels.style.display,'flex');
 assert.equal(labels.style.justifyContent,'space-between');
 assert.equal(labels.style.fontSize,'9px');
 assert.equal(labels.style.color,'#69746c');
 assert.equal(labels.style.marginTop,'2px');
 assert.deepEqual(labels.children.map(span=>span.textContent),['09/28 03:00','09/28 06:00']);
});

test('default hover strings switch to English when the document language is not zh',()=>{
 const api=setup('en-US');
 const container=fakeNode();
 const at=Date.UTC(2026,8,28,14,30,0);
 api.cycleBars(container,{cycles:[{resetsAt:at,peakPercent:58}],tint:'#507a59'});
 assert.equal(container.children[0].children[0].children[0].textContent,'09/28 14:30 · left 42%');
 const hours=fakeNode();
 api.hourlyBars(hours,{buckets:[{hourStart:at,consumedPercent:30}]});
 assert.equal(hours.children[0].children[0].children[0].textContent,'09/28 14:00 · used 30%');
 assert.deepEqual(hours.children[1].children.map(span=>span.textContent),['09/28 14:00','09/28 15:00']);
});
