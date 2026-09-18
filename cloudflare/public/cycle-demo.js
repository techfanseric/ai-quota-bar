// Ported from MenuBarSelfTestFrame, MenuBarPaceGlyph and MenuBarTaskEnergyMotion.
// Fictional demonstration values; no account or task data is requested.
export function selfTestFrame(elapsed) {
 const position = (Math.max(0, elapsed) % 3) / 3;
 const phase = Math.min(2, Math.floor(position * 3));
 const local = position * 3 - phase, eased = local * local * (3 - 2 * local);
 const delta = 3 + (200 / 7 - 3) * eased;
 return { remaining: (50 - 42 * Math.cos(position * 2 * Math.PI)) / 100, delta: phase === 0 ? -delta : phase === 1 ? 0 : delta };
}
export function waveCount(tasks) { return Math.min(5, Math.max(0, Math.floor(tasks))); }
export function paceFill(delta) { return Math.abs(delta) <= 2 ? 0 : Math.min(1, Math.ceil(Math.abs(delta) / (200 / 7) * 4) / 4); }
export function waveHead(elapsed, index, count) { return (1 - ((elapsed / 1.8 + index / count) % 1) + 1) % 1; }
const ns = 'http://www.w3.org/2000/svg';
function node(tag, attrs = {}, text) { const n = document.createElementNS(ns, tag); for (const [k,v] of Object.entries(attrs)) n.setAttribute(k,v); if (text) n.textContent=text; return n; }
function arc(start,end,r=8) {
 const p = t => [11 + r * Math.sin(t * Math.PI * 2),11 - r * Math.cos(t * Math.PI * 2)];
 const a=p(start),b=p(end);return `M${a}A${r},${r} 0 ${end-start>.5?1:0} 1 ${b}`;
}
function draw(svg, elapsed, remaining, delta, tasks, initial) {
	const count=waveCount(tasks), children=[];
	children.push(node('circle',{cx:11,cy:11,r:8,fill:'none',stroke:'currentColor','stroke-opacity':.12,'stroke-width':1.4}));
	if(remaining>0)children.push(node('path',{d:arc(0,Math.min(.99999,remaining)),fill:'none',stroke:'currentColor','stroke-opacity':count?.6:1,'stroke-width':2.4,'stroke-linecap':'round'}));
	if(!count&&remaining>.01&&remaining<.99) {
		// 静止时的进度端点圆点（drawProgressEndpoint，r=1.35）。
		const a=Math.PI/2-Math.PI*2*remaining;
		children.push(node('circle',{cx:11+Math.cos(a)*8,cy:11-Math.sin(a)*8,r:1.35,fill:'currentColor'}));
	}
	for(let i=0;i<count;i++) {
		const head=waveHead(elapsed,i,count),span=Math.min(.16,1/(count*1.45));
		for(let segment=0;segment<6;segment++) {
			const start=head+segment*span/6,end=start+span/6*1.08;
			// Split at quota boundary and wrap so thick/thin waves match native geometry.
			const cuts=[start,end];for(let turn=0;turn<3;turn++)for(const point of [turn,turn+remaining])if(point>start&&point<end)cuts.push(point);
			cuts.sort((a,b)=>a-b);
			for(let j=0;j<cuts.length-1;j++) {const mid=(cuts[j]+cuts[j+1])/2,active=(mid%1)<remaining;
				children.push(node('path',{d:arc(cuts[j],cuts[j+1]),fill:'none',stroke:'currentColor','stroke-width':active?2.6:1.6,'stroke-opacity':.78*Math.pow(1-(segment+.54)/6,.65)*(active?1:.45),'stroke-linecap':'round'}));
			}
		}
	}
	children.push(node('circle',{cx:11,cy:11,r:4.25,fill:'none',stroke:'currentColor','stroke-opacity':.12,'stroke-width':.7}));
	const fill=paceFill(delta),id=svg.dataset.clip;
	children.push(node('defs',{},null));children.at(-1).append(node('clipPath',{id}));children.at(-1).firstChild.append(node('circle',{cx:11,cy:11,r:4.25}));
	if(fill)children.push(node('rect',{x:delta<0?11-4.25*fill:11,y:6.75,width:4.25*fill,height:8.5,fill:'currentColor','fill-opacity':.86,'clip-path':`url(#${id})`}));
	// 中心半圆边框：透支高亮左半，盈余高亮右半（drawCodexCore，1.05 宽）。
	const deficit=delta<0;
	children.push(node('path',{d:'M11 6.75A4.25 4.25 0 0 0 11 15.25',fill:'none',stroke:'currentColor','stroke-width':1.05,'stroke-opacity':deficit?.86:.12}));
	children.push(node('path',{d:'M11 6.75A4.25 4.25 0 0 1 11 15.25',fill:'none',stroke:'currentColor','stroke-width':1.05,'stroke-opacity':deficit?.12:.86}));
	children.push(node('path',{d:'M11 7.3V14.7',stroke:'currentColor','stroke-width':1}));
	const core=node('g',{'class':'cycle-core'});core.append(...children.splice(children.length-(fill?6:5)));
	// The quota ring remains visible while hover reveals the provider initial.
	const label=node('text',{x:11,y:14.1,'text-anchor':'middle','font-size':9,'font-weight':600,fill:'currentColor',class:'cycle-initial'},initial);
	svg.replaceChildren(...children,core,label);
}
if(typeof document !== 'undefined') {
	 // 四个状态平铺展示：自检/单任务/多任务持续演示各自的运动，空闲天然静止。
	 const stateSpecs={
	  selftest:{tasks:0,animated:true},
	  idle:{remaining:.64,delta:0,tasks:0,animated:false},
	  single:{remaining:.64,delta:7,tasks:1,animated:true},
	  multiple:{remaining:.58,delta:-8,tasks:3,animated:true},
	 };
	 const stateIcons=[...document.querySelectorAll('[data-cycle-state]')]
	  .map(svg=>({svg,spec:stateSpecs[svg.dataset.cycleState]}))
	  .filter(item=>item.spec);
	 const liveIcons=[...document.querySelectorAll('[data-cycle-icon]')];
	 [...stateIcons.map(i=>i.svg),...liveIcons].forEach((s,i)=>s.dataset.clip=`cycle-clip-${i}`);
	 const reduced=matchMedia('(prefers-reduced-motion: reduce)');
	 let elapsed=0,last=0,visible=false,raf=0;
	 function renderStaticFrame() {
	  // 减弱动态偏好下的代表性定格：自检取盈余帧，其余取各自状态。
	  const f=selfTestFrame(1.05);
	  for(const {svg,spec} of stateIcons) {
	   if(svg.dataset.cycleState==='selftest')draw(svg,0,f.remaining,f.delta,0,'C');
	   else draw(svg,.55,spec.remaining,spec.delta,spec.tasks,'C');
	  }
	  liveIcons.forEach(s=>{const kimi=s.dataset.cycleIcon==='kimi';
	   draw(s,.55,kimi?.42:.64,kimi?-8:7,kimi?2:1,kimi?'K':'C');});
	 }
	 function render() {
	  for(const {svg,spec} of stateIcons) {
	   if(!spec.animated)draw(svg,0,spec.remaining,spec.delta,0,'C');
	   else if(svg.dataset.cycleState==='selftest'){const f=selfTestFrame(elapsed);draw(svg,elapsed,f.remaining,f.delta,0,'C');}
	   else draw(svg,elapsed,spec.remaining,spec.delta,spec.tasks,'C');
	  }
	  liveIcons.forEach(s=>{const kimi=s.dataset.cycleIcon==='kimi';
	   draw(s,elapsed,kimi?.42:.64,kimi?-8:7,kimi?2:1,kimi?'K':'C');});
	 }
	 function tick(now) {raf=0;if(!visible||document.hidden)return;
	  if(now-last>=1000/15){elapsed+=(now-last)/1000;last=now;render();}
	  raf=requestAnimationFrame(tick);}
	 function run() {cancelAnimationFrame(raf);last=performance.now();
	  if(!reduced.matches&&visible&&!document.hidden)raf=requestAnimationFrame(tick);}
	 reduced.addEventListener?.('change',()=>reduced.matches?renderStaticFrame():run());
	 document.addEventListener('visibilitychange',run);
	 const targets=new Set();
	 const observer=new IntersectionObserver(entries=>{
	  for(const e of entries)e.isIntersecting?targets.add(e.target):targets.delete(e.target);
	  visible=targets.size>0;run();});
	 for(const el of document.querySelectorAll('.cycle-states, .desktop-strip'))observer.observe(el);
	 if(reduced.matches)renderStaticFrame();else{render();run();}
	}
