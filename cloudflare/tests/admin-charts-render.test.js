import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync} from 'node:fs';

// app layout: MenuView QuotaChartLayout insets inside an 84pt frame.
const LEFT=30, RIGHT=8, TOP=8, BOTTOM=18, HEIGHT=84;
const PLOT_BOTTOM=TOP+HEIGHT-TOP-BOTTOM;

const source=readFileSync(new URL('../public/admin-charts.js',import.meta.url),'utf8');
const fakeNode=tag=>({tag,attributes:{},children:[],style:{},textContent:'',hidden:false,clientWidth:0,
  offsetLeft:0,offsetWidth:0,listeners:{},
  setAttribute(key,value){this.attributes[key]=String(value);},
  append(...nodes){this.children.push(...nodes);},
  appendChild(node){this.children.push(node);return node;},
  addEventListener(event,fn){this.listeners[event]=fn;}});
const setup=lang=>{
 const ctx=vm.createContext({document:{documentElement:{lang},
  createElement:tag=>fakeNode(tag),createElementNS:(ns,tag)=>fakeNode(tag)}});
 vm.runInContext('var window=this;',ctx);
 vm.runInContext(source,ctx);
 return vm.runInContext('window.AdminQuotaCharts',ctx);
};
const byTag=(node,tag)=>node.children.filter(child=>child.tag===tag);
const texts=node=>byTag(node,'text').map(child=>child.textContent);
const gridTicks=chart=>byTag(chart,'line').filter(node=>node.attributes['stroke-dasharray']==='2,3');
const container=width=>{const node=fakeNode();node.clientWidth=width;return node;};
const round=n=>Math.round(n*100)/100;

test('curve() mirrors the app chart: plate, axes, warning line, grid, pace guide, gradient, dots',()=>{
 const api=setup('zh-CN');
 const box=container(320);
 const start=Date.UTC(2026,8,28,0,0,0),end=Date.UTC(2026,8,28,5,0,0);
 const chart=api.curve(box,{points:[{t:start+1800000,y:87.5},{t:start+9000000,y:55},{t:start+18000000,y:120}],
  windowStart:start,windowEnd:end,yMax:100,tint:'#507a59',warningThreshold:20,
  pace:{expectedUsedPercent:41.2,ahead:true}});
 assert.equal(chart,box.children[0]);
 assert.equal(chart.attributes.viewBox,`0 0 320 ${HEIGHT}`);
 assert.equal(chart.attributes.height,String(HEIGHT));
 const plates=byTag(chart,'rect');
 assert.equal(plates.length,1);
 assert.deepEqual([plates[0].attributes.x,plates[0].attributes.y,plates[0].attributes.width,plates[0].attributes.height],
  [String(LEFT),String(TOP),String(320-LEFT-RIGHT),String(PLOT_BOTTOM-TOP)]);
 assert.equal(plates[0].attributes.rx,'7');
 assert.equal(plates[0].attributes.fill,'rgba(0,0,0,0.035)');
 const axes=byTag(chart,'line').filter(node=>node.attributes.stroke==='rgba(0,0,0,0.14)');
 assert.equal(axes.length,2);
 assert.equal(axes[0].x1||axes[0].attributes.x1,String(LEFT));
 assert.equal(axes[1].attributes.y2,String(PLOT_BOTTOM));
 // warning threshold: the app's 20% remaining line, dashed orange.
 const warning=byTag(chart,'line').find(node=>node.attributes.stroke==='rgba(176,122,42,0.45)');
 assert.ok(warning);
 assert.equal(warning.attributes['stroke-dasharray'],'3,3');
 assert.equal(warning.attributes.y1,String(round(PLOT_BOTTOM-0.2*(PLOT_BOTTOM-TOP))));
 assert.equal(gridTicks(chart).length,4);
 for(const tick of gridTicks(chart)){
  assert.equal(tick.attributes.stroke,'rgba(0,0,0,0.10)');
  assert.equal(tick.attributes.x1,tick.attributes.x2);
 }
 // pace guide: diagonal from the full quota corner to the reset corner.
 const pace=byTag(chart,'line').find(node=>node.attributes['stroke-dasharray']==='3,3'&&node.attributes.stroke!=='rgba(176,122,42,0.45)');
 assert.ok(pace,'pace guide line');
 assert.equal(pace.attributes.stroke,'#507a59');
 assert.equal(pace.attributes['stroke-opacity'],'0.55');
 assert.deepEqual([pace.attributes.x1,pace.attributes.y1,pace.attributes.x2,pace.attributes.y2],
  [String(LEFT),String(TOP),String(320-RIGHT),String(PLOT_BOTTOM)]);
 // 中文界面按 UTC+8 读小时与日界线。
 assert.deepEqual(texts(chart),['100%','0','08:00','13:00']);
 const gradient=byTag(chart,'defs')[0].children[0];
 assert.match(gradient.attributes.id,/^aqb-grad-/);
 assert.deepEqual(gradient.children.map(stop=>stop.attributes['stop-opacity']),['0.22','0.03']);
 assert.ok(gradient.children.every(stop=>stop.attributes['stop-color']==='#507a59'));
 const paths=byTag(chart,'path');
 assert.equal(paths.length,1);
 assert.equal(paths[0].attributes.fill,`url(#${gradient.attributes.id})`);
 assert.match(paths[0].attributes.d,new RegExp(`L ${320-RIGHT} ${PLOT_BOTTOM} L .* ${PLOT_BOTTOM} Z$`));
 const polylines=byTag(chart,'polyline');
 assert.equal(polylines.length,1);
 assert.equal(polylines[0].attributes['stroke-width'],'2');
 assert.equal(polylines[0].attributes['stroke-linecap'],'round');
 assert.equal(polylines[0].attributes['stroke-linejoin'],'round');
 const dots=byTag(chart,'circle').filter(node=>node.attributes.r==='2');
 assert.equal(dots.length,3);
 assert.ok(dots.every(point=>point.attributes.fill==='#507a59'));
});

test('curve() with one sample draws a vertical guide and a single marker, no area',()=>{
 const api=setup('zh-CN');
 const start=Date.UTC(2026,8,28,0,0,0);
 const chart=api.curve(container(),{points:[{t:start+9000000,y:42}],
  windowStart:start,windowEnd:start+18000000,yMax:100,tint:'#507a59'});
 assert.equal(byTag(chart,'polyline').length,0);
 assert.equal(byTag(chart,'path').length,0);
 const guides=byTag(chart,'line').filter(node=>node.attributes['stroke-opacity']==='0.45');
 assert.equal(guides.length,1);
 assert.equal(guides[0].attributes['stroke-width'],'2');
 assert.equal(guides[0].attributes.x1,guides[0].attributes.x2);
 const markers=byTag(chart,'circle').filter(node=>node.attributes.r==='3');
 assert.equal(markers.length,1);
});

test('curve() grid follows the app rule: hours inside a day, local midnights for weeks, none past eight days',()=>{
 const api=setup('zh-CN');
 const start=Date.UTC(2026,8,28,0,0,0);
 assert.equal(gridTicks(api.curve(container(320),{points:[],windowStart:start,
  windowEnd:Date.UTC(2026,8,28,5,0,0),yMax:100,tint:'#507a59'})).length,4);
 assert.equal(gridTicks(api.curve(container(320),{points:[],windowStart:start,
  windowEnd:Date.UTC(2026,8,28,23,0,0),yMax:100,tint:'#507a59'})).length,22);
 // 09/28T00:00Z~10/01T00:00Z 在 +8 下跨 3 个本地零点。
 assert.equal(gridTicks(api.curve(container(320),{points:[],windowStart:start,
  windowEnd:Date.UTC(2026,9,1,0,0,0),yMax:100,tint:'#507a59'})).length,3);
 assert.equal(gridTicks(api.curve(container(320),{points:[],windowStart:Date.UTC(2026,0,1),
  windowEnd:Date.UTC(2026,3,1),yMax:100,tint:'#507a59'})).length,0);
});

test('curve() counts a non-percent window on its own axis and labels cross-day ends with the date',()=>{
 const api=setup('zh-CN');
 const start=Date.UTC(2026,8,28,22,0,0);
 const chart=api.curve(container(320),{points:[{t:start+3600000,y:340}],windowStart:start,
  windowEnd:Date.UTC(2026,8,29,3,0,0),yMax:500,tint:'#507a59'});
 assert.deepEqual(texts(chart).slice(0,2),['500','0']);
 // 22:00Z~03:00Z 在 +8 下是同一天的 06:00~11:00，轴标签省掉日期（与 App 一致）。
 assert.deepEqual(texts(chart).slice(2),['06:00','11:00']);
 const utc=setup('en-US').curve(container(320),{points:[],windowStart:start,
  windowEnd:Date.UTC(2026,8,29,3,0,0),yMax:500,tint:'#507a59'});
 assert.deepEqual(texts(utc).slice(2),['22:00','09/29 03:00']);
});

test('cycleBars() draws app-style tracks, fills sized by peak used%, and greys full cycles',()=>{
 const api=setup('zh-CN');
 const box=container(200);
 const base=Date.UTC(2026,8,28,3,0,0);
 const cycles=[{resetsAt:base+10800000,peakPercent:10},{resetsAt:base+7200000,peakPercent:85},
  {resetsAt:base+3600000,peakPercent:40},{resetsAt:base,peakPercent:100}];
 const row=api.cycleBars(box,{cycles,tint:'#507a59',cycleDuration:3600000});
 assert.equal(box.children.length,2); // columns + hover callout
 assert.equal(box.children[0],row);
 assert.equal(box.children[1].className,'chart-callout');
 assert.equal(box.children[1].hidden,true);
 assert.equal(row.style.display,'flex');
 assert.equal(row.style.alignItems,'flex-end');
 assert.equal(row.style.justifyContent,'center');
 assert.equal(row.style.gap,'2px');
 assert.equal(row.style.height,'30px');
 assert.equal(row.children.length,4);
 // track + fill + left% label per column; height = peak used%.
 for(const bar of row.children){
  assert.equal(bar.style.maxWidth,'16px');
  assert.equal(bar.style.minWidth,'3px');
  assert.equal(bar.style.borderRadius,'1.5px');
  assert.equal(bar.style.background,'rgba(40,53,46,0.07)');
  assert.equal(bar.children[1].className,'cycle-label');
 }
 assert.deepEqual(row.children.map(bar=>bar.children[0].style.height),['100%','40%','85%','10%']);
 assert.deepEqual(row.children.map(bar=>bar.children[0].style.background),['#507a59','#507a59','#507a59','#507a59']);
 assert.deepEqual(row.children.map(bar=>bar.children[1].textContent),['0','60','15','90']);
 assert.deepEqual(row.children.map(bar=>bar.attributes.title),
  ['10:00-11:00 · 0%','11:00-12:00 · 60%','12:00-13:00 · 15%','13:00-14:00 · 90%']);
});

test('cycleBars() uses a date range for day-long cycles and a custom label when asked',()=>{
 const api=setup('en-US');
 const box=container(200);
 const end=Date.UTC(2026,8,28,0,0,0);
 api.cycleBars(box,{cycles:[{resetsAt:end,peakPercent:40}],tint:'#507a59',cycleDuration:7*86400000});
 assert.equal(box.children[0].children[0].attributes.title,'09/21-09/28 · 60%');
 // 短周期同样按 +8 显示：00:00Z 结束 → 本地 08:00，窗口 07:00~08:00 跨天。
 const short=container(200);
 api.cycleBars(short,{cycles:[{resetsAt:end,peakPercent:40}],tint:'#507a59',cycleDuration:3600000});
 assert.equal(short.children[0].children[0].attributes.title,'09/27 23:00-09/28 00:00 · 60%');
 const custom=container(200);
 api.cycleBars(custom,{cycles:[{resetsAt:end,peakPercent:40}],tint:'#507a59',label:cycle=>'peak '+cycle.peakPercent});
 assert.equal(custom.children[0].children[0].attributes.title,'peak 40');
});

test('hourlyBars() renders per-hour bars with thresholds and a first/last label line',()=>{
 const api=setup('zh-CN');
 const box=container(200);
 const base=Date.UTC(2026,8,28,3,0,0);
 api.hourlyBars(box,{buckets:[{hourStart:base+7200000,consumedPercent:60},
  {hourStart:base,consumedPercent:30},{hourStart:base+3600000,consumedPercent:85}]});
 assert.equal(box.children.length,2);
 const row=box.children[0];
 assert.equal(row.children.length,3);
 assert.deepEqual(row.children.map(bar=>bar.style.height),['30%','85%','60%']);
 assert.deepEqual(row.children.map(bar=>bar.style.background),['#507a59','#b07a2a','#507a59']);
 assert.deepEqual(row.children.map(bar=>bar.children[0].textContent),
  ['09/28 11:00 · 耗 30%','09/28 12:00 · 耗 85%','09/28 13:00 · 耗 60%']);
 const labels=box.children[1];
 assert.equal(labels.style.display,'flex');
 assert.equal(labels.style.justifyContent,'space-between');
 assert.equal(labels.style.fontSize,'9px');
 assert.deepEqual(labels.children.map(span=>span.textContent),['09/28 11:00','09/28 14:00']);
});

test('a narrow column drops chart furniture instead of shrinking the 296pt menu chart',()=>{
 const api=setup('zh-CN');
 // 周窗口：两端标签带日期，正是窄列里最先挤在一起的一对。
 const start=Date.UTC(2026,8,22,6,0,0),end=Date.UTC(2026,8,29,11,0,0);
 const points=[{t:start+86400000,y:88},{t:start+4*86400000,y:71},
  {t:start+6*86400000,y:64},{t:start+9*86400000,y:57}];
 const spec={points,windowStart:start,windowEnd:end,yMax:100,tint:'#507a59',warningThreshold:20,
  pace:{ahead:false}};
 // 150px 容器 → 绘图区 150-30-8 = 112px，低于 190 的窄图阈值。
 const narrow=api.curve(container(150),spec);
 assert.equal(gridTicks(narrow).length,0,'窄图不画时间网格线');
 // 纵轴只剩顶部一个刻度，右对齐贴在轴线左侧，不再压进绘图区；
 // 底部的 0 让给左下角的时间标签。
 const labels=texts(narrow);
 assert.deepEqual(labels.filter(text=>/%\s*$/.test(text)||text==='100%'),['100%']);
 assert.ok(!labels.includes('0'),'窄图不画底部 0 刻度');
 const top=narrow.children.find(node=>node.tag==='text'&&node.textContent==='100%');
 assert.equal(top.attributes['text-anchor'],'end');
 assert.equal(top.attributes.x,String(LEFT-4));
 assert.equal(top.attributes['font-size'],'8');
 // 对角参考线保留但压到 0.3，只留暗示。
 assert.equal(narrow.children.filter(node=>node.tag==='line'&&node.attributes['stroke-opacity']==='0.3').length,1);
 // 起止时间各留一端（160px 是图宽下限，两端标签恒放得下）。
 assert.deepEqual(labels.filter(text=>/\d\d:\d\d$/.test(text)),['14:00','09/29 19:00']);
 // 同一份数据在 296px 的菜单宽度下仍是完整版：网格线、0 刻度、两端标签都在。
 const wide=api.curve(container(296),spec);
 assert.equal(gridTicks(wide).length,7);
 assert.ok(texts(wide).includes('0'));
 assert.deepEqual(texts(wide).filter(text=>/\d\d:\d\d$/.test(text)),['14:00','09/29 19:00']);
 assert.equal(wide.children.filter(node=>node.tag==='line'&&node.attributes['stroke-opacity']==='0.55').length,1);
});

test('bar width is derived from the container, and a narrow column drops the oldest cycles',()=>{
 const api=setup('zh-CN');
 const base=Date.UTC(2026,8,28,0,0,0);
 const make=count=>Array.from({length:count},(_,index)=>({resetsAt:base+index*3600000,peakPercent:index}));
 const widthOf=(n,w)=>api.cycleBars(container(w),{cycles:make(n),tint:'#507a59'}).children[0].style.maxWidth;
 // 柱宽由容器反推、上限 16px：柱子少的账号拿到宽柱，柱子多的自然收窄，
 // 不管几个模型柱子条都铺满整张卡片。
 assert.equal(widthOf(1,200),'16px');
 assert.equal(widthOf(2,200),'16px');
 assert.equal(widthOf(6,200),'16px');
 assert.equal(widthOf(12,200),'14px');
 assert.equal(widthOf(30,200),'4px');
 assert.equal(widthOf(30,356),'9px');
 // 收到 3px 还放不下就丢掉最老的周期，留最近的那些。
 const narrow=container(100);
 const row=api.cycleBars(narrow,{cycles:make(30),tint:'#507a59',cycleDuration:3600000});
 assert.equal(row.children.length,20);
 assert.equal(row.children[0].style.maxWidth,'3px');
 assert.deepEqual(row.children.map(bar=>bar.children[0].style.height),
  Array.from({length:20},(_,index)=>`${index+10}%`));
 assert.equal(row.children[0].attributes.title,'17:00-18:00 · 90%');
 assert.equal(row.children[19].attributes.title,'12:00-13:00 · 71%');
 // 柱距不到 9px 时不再挂悬停数字（会盖住邻居），交给整行的气泡。
 assert.equal(row.children[0].children.length,1);
 // 量不到宽度（隐藏容器／无 layout）时不裁剪，回到 App 的 10px。
 const hidden=api.cycleBars(container(0),{cycles:make(30),tint:'#507a59'});
 assert.equal(hidden.children.length,30);
 assert.equal(hidden.children[0].style.maxWidth,'10px');
 // 每小时消耗同一套规则：时间轴的首尾标签跟着裁剪后的区间走。
 const hourBox=container(100);
 api.hourlyBars(hourBox,{buckets:make(48).map(bucket=>({hourStart:bucket.resetsAt,consumedPercent:bucket.peakPercent}))});
 assert.equal(hourBox.children[0].children.length,20);
 assert.equal(hourBox.children[0].children[0].children[0].textContent,'09/29 12:00 · 耗 28%');
 assert.deepEqual(hourBox.children[1].children.map(span=>span.textContent),['09/29 12:00','09/30 08:00']);
});

test('default hover strings switch to English when the document language is not zh',()=>{
 const api=setup('en-US');
 const box=container(200);
 const at=Date.UTC(2026,8,28,14,30,0);
 api.cycleBars(box,{cycles:[{resetsAt:at,peakPercent:58}],tint:'#507a59',cycleDuration:3600000});
 assert.equal(box.children[0].children[0].attributes.title,'13:30-14:30 · 42%');
 const hours=container(200);
 api.hourlyBars(hours,{buckets:[{hourStart:at,consumedPercent:30}]});
 assert.equal(hours.children[0].children[0].children[0].textContent,'09/28 14:00 · used 30%');
});
