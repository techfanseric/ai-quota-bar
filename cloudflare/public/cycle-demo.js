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
 children.push(node('path',{d:'M11 7.3V14.7',stroke:'currentColor','stroke-width':1}));
 const core=node('g',{'class':'cycle-core'});core.append(...children.splice(children.length-(fill?4:3)));
 // The quota ring remains visible while hover reveals the provider initial.
 const label=node('text',{x:11,y:14.1,'text-anchor':'middle','font-size':9,'font-weight':600,fill:'currentColor',class:'cycle-initial'},initial);
 svg.replaceChildren(...children,core,label);
}
if(typeof document !== 'undefined') {
 const panel=document.querySelector('#cycle-demo');
 if(panel) {
  const descriptions={selftest:['自检 · 3 秒循环','外环在 8%–92% 间扫动；中心依次演示透支、正常和盈余。'],idle:['空闲 · 额度与节奏','没有活跃任务时，图标保持静止。外环显示 Weekly 剩余，中心向左为透支，向右为盈余。'],single:['1 个任务 · 1 条光带','一条光带每 1.8 秒逆时针绕行。经过已消耗的区域时，光带会变细、变淡。'],multiple:['多个任务 · 各自可见','示例中 Codex 有 3 个任务，Kimi 有 2 个，各自显示对应数量的光带；每个图标最多显示 5 条。']};
  const svgs=[...document.querySelectorAll('[data-cycle-icon]')];svgs.forEach((s,i)=>s.dataset.clip=`cycle-clip-${i}`);
  const reduced=matchMedia('(prefers-reduced-motion: reduce)');let paused=reduced.matches,mode='selftest',elapsed=0,last=0,visible=false,raf=0;
  const pause=panel.querySelector('[data-cycle-pause]');
  function render() {
   const f=mode==='selftest'?selfTestFrame(elapsed):{remaining:.64,delta:7};
   svgs.forEach(s=>{const kimi=s.dataset.cycleIcon==='kimi';s.closest('[data-kimi]')?.toggleAttribute('hidden',mode!=='multiple');draw(s,elapsed,kimi?.42:f.remaining,kimi?-8:f.delta,mode==='single'?1:mode==='multiple'?(kimi?2:3):0,kimi?'K':'C');});
  }
  function tick(now) {raf=0;if(paused||!visible||document.hidden)return;if(now-last>=1000/15){elapsed+=(now-last)/1000;last=now;render();}raf=requestAnimationFrame(tick);}
  function run() {cancelAnimationFrame(raf);last=performance.now();if(!paused&&visible&&!document.hidden&&mode!=='idle')raf=requestAnimationFrame(tick);}
  function select(value) {mode=value;elapsed=0;panel.querySelectorAll('[data-cycle-mode]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.cycleMode===mode)));panel.querySelector('[data-cycle-title]').textContent=descriptions[mode][0];panel.querySelector('[data-cycle-description]').textContent=descriptions[mode][1];render();run();}
  panel.querySelectorAll('[data-cycle-mode]').forEach(b=>b.addEventListener('click',()=>select(b.dataset.cycleMode)));
  function setPause(value){paused=value;pause.textContent=paused?'播放演示':'暂停动画';pause.setAttribute('aria-pressed',String(paused));run();}
  pause.addEventListener('click',()=>setPause(!paused));reduced.addEventListener('change',e=>setPause(e.matches));document.addEventListener('visibilitychange',run);
  // Run while either the detailed demo or the menu bar in the hero is visible.
  const targets=new Set();new IntersectionObserver(entries=>{for(const e of entries)e.isIntersecting?targets.add(e.target):targets.delete(e.target);visible=targets.size>0;run();}).observe(panel);
  const hero=document.querySelector('.desktop-strip');new IntersectionObserver(entries=>{for(const e of entries)e.isIntersecting?targets.add(e.target):targets.delete(e.target);visible=targets.size>0;run();}).observe(hero);
  select(mode);setPause(paused);
 }
}
