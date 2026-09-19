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
function arc(start,end) {
 const p = t => { const a=(38-256*t)*Math.PI/180;return [11+7.61*Math.cos(a),12.05-7.61*Math.sin(a)]; };
 const a=p(start),b=p(end);return `M${a}A7.61,7.61 0 ${(end-start)*256>180?1:0} 1 ${b}`;
}
export function fanSectorPath(sign,inner,outer,fraction) {
 const mid=sign>0?90:270,start=mid-55*fraction,end=mid+55*fraction;
 const p=(r,a)=>[11+r*20/410*Math.cos(a*Math.PI/180),12.05-r*20/410*Math.sin(a*Math.PI/180)];
 const a=p(outer,start),b=p(outer,end),c=p(inner,end),d=p(inner,start);
 return `M${a}A${outer*20/410},${outer*20/410} 0 0 0 ${b}L${c}A${inner*20/410},${inner*20/410} 0 0 1 ${d}Z`;
}
export function visibleArcInterval(start,end) {
 const openingEnd=(90-38)/360,span=256/360;
 const lower=Math.max(start,openingEnd),upper=Math.min(end,openingEnd+span);
 return upper>lower?[Math.max(0,(lower-openingEnd)/span),Math.min(1,(upper-openingEnd)/span)]:null;
}
function draw(svg, elapsed, remaining, delta, tasks, initial) {
 const count=waveCount(tasks), children=[];
 children.push(node('path',{d:arc(0,1),fill:'none',stroke:'currentColor','stroke-opacity':.18,'stroke-width':2.68,'stroke-linecap':'round'}));
 if(remaining>0)children.push(node('path',{d:arc(0,Math.min(1,remaining)),fill:'none',stroke:remaining<=.2?'#d6a00a':'currentColor','stroke-opacity':1,'stroke-width':2.68,'stroke-linecap':'round'}));
 for(let i=0;i<count;i++) {
  const head=waveHead(elapsed,i,count),span=Math.min(.16,1/(count*1.45));
  for(let segment=0;segment<16;segment++) {
   const start=head+segment*span/16,end=start+span/16;
   for(let turn=Math.floor(start);turn<=Math.floor(end);turn++) {
    const visible=visibleArcInterval(Math.max(0,start-turn),Math.min(1,end-turn));
    if(!visible)continue;
    const cuts=[...visible];if(remaining>cuts[0]&&remaining<cuts[1])cuts.splice(1,0,remaining);
    for(let j=0;j<cuts.length-1;j++) {
     const active=(cuts[j]+cuts[j+1])/2<remaining;
     children.push(node('path',{d:arc(cuts[j],cuts[j+1]),fill:'none',stroke:active?'var(--cycle-highlight, #fff)':'currentColor','stroke-width':1.15,'stroke-opacity':.78*Math.pow(1-(segment+.5)/16,.65)*(active?1:.45)}));
    }
   }
  }

 }
 const known=Number.isFinite(delta),fill=known?paceFill(delta)*2:0;
 children.push(node('circle',{cx:11,cy:12.05,r:38/2*20/410,fill:'currentColor','fill-opacity':known?1:.18}));
 for(const sign of [-1,1])for(const [index,inner,outer] of [[0,42,69],[1,82,109]]) {
  children.push(node('path',{d:fanSectorPath(sign,inner,outer,1),fill:'currentColor','fill-opacity':.18}));
  const amount=Math.min(1,Math.max(0,fill-index));
  if(known&&delta*sign>0&&amount>0)children.push(node('path',{d:fanSectorPath(sign,inner,outer,amount),fill:'currentColor'}));
 }
 children.push(node('text',{x:11,y:6.6,'text-anchor':'middle','font-size':6.34,'font-weight':700,fill:'currentColor'},initial));
 svg.replaceChildren(...children);
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
	  liveIcons.forEach(s=>{
	   const spec=liveSpecs[s.dataset.cycleIcon]||{remaining:.6,tasks:0},initial=s.dataset.cycleIcon[0].toUpperCase();
	   draw(s,.55,spec.remaining,spec.delta,spec.tasks,initial);});
	 }
	 function render() {
	  for(const {svg,spec} of stateIcons) {
	   if(!spec.animated)draw(svg,0,spec.remaining,spec.delta,0,'C');
	   else if(svg.dataset.cycleState==='selftest'){const f=selfTestFrame(elapsed);draw(svg,elapsed,f.remaining,f.delta,0,'C');}
	   else draw(svg,elapsed,spec.remaining,spec.delta,spec.tasks,'C');
	  }
	  renderLiveRings();
	 }
	 function tick(now) {raf=0;if(!visible||document.hidden)return;
	  if(now-last>=1000/30){elapsed+=(now-last)/1000;last=now;render();}
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
	 // Both hero rings and state cards share the native pace core and task renderer.
	 const liveSpecs={codex:{remaining:.64,delta:7,tasks:1},kimi:{remaining:.42,delta:-8,tasks:3},minimax:{remaining:.75,tasks:0},glm:{remaining:.58,tasks:0}};
	 function renderLiveRings(){liveIcons.forEach(s=>{
	  const spec=liveSpecs[s.dataset.cycleIcon]||{remaining:.6,tasks:0},initial=s.dataset.cycleIcon[0].toUpperCase();
	  draw(s,elapsed,spec.remaining,spec.delta,spec.tasks,initial);});}
	 renderLiveRings();
	 if(reduced.matches)renderStaticFrame();else{render();run();}
	}
