// Pure rendering for the /admin account quota rows, mirroring the macOS app's
// left-click menu (AIQuotaBar/Views/MenuView.swift): QuotaAreaChart,
// PaceTipStripes and ModelUtilizationBarsView. No fetching, no module state —
// admin-quota.js owns the data and calls window.AdminQuotaCharts.curve /
// .cycleBars / .hourlyBars(container, spec).
// CSP-safe: no innerHTML, no <style> injection, no inline handlers.
window.AdminQuotaCharts=(()=>{
 const NS='http://www.w3.org/2000/svg',HOUR=3600000,DAY=86400000;
 // MenuView QuotaChartLayout: leftInset 30 / rightInset 8 / topInset 8 /
 // bottomInset 18 inside the chart's fixed 84pt frame.
 const FRAME={left:30,right:8,top:8,bottom:18,height:84};
 // App tint semantics (ModelRow.tint): red / orange / green / secondary.
 const TINT={red:'#9b4a32',orange:'#b07a2a',green:'#507a59',secondary:'#8a948d'};
 const zh=()=>document.documentElement.lang.indexOf('zh')===0;
 // 展示时区与 admin-quota.js 一致：中文界面 UTC+8，英文界面 UTC。只影响显示与格子切分。
 const tzOffset=()=>document.documentElement.lang.indexOf('zh')===0?480:0;
 const localDate=t=>new Date(t+tzOffset()*60000);
 const p2=n=>String(n).padStart(2,'0');
 const md=t=>{const d=localDate(t);return p2(d.getUTCMonth()+1)+'/'+p2(d.getUTCDate());};
 const hm=t=>{const d=localDate(t);return p2(d.getUTCHours())+':'+p2(d.getUTCMinutes());};
 const mh=t=>md(t)+' '+hm(t);
 const h0=t=>md(t)+' '+p2(localDate(t).getUTCHours())+':00';
 const nextHour=t=>Math.floor((t+tzOffset()*60000)/HOUR)*HOUR+HOUR-tzOffset()*60000;
 const nextMidnight=t=>Math.floor((t+tzOffset()*60000)/DAY)*DAY+DAY-tzOffset()*60000;
 const clamp=(v,lo,hi)=>Math.min(hi,Math.max(lo,v));
 const round=n=>Math.round(n*100)/100;
 const set=(node,props)=>{for(const key in props)node.setAttribute(key,String(props[key]));return node;};
 const svg=tag=>document.createElementNS(NS,tag);
 const line=(x1,y1,x2,y2,color,width,dash,opacity)=>set(svg('line'),{x1:round(x1),y1:round(y1),x2:round(x2),y2:round(y2),
  stroke:color,'stroke-width':width||1,...(dash?{'stroke-dasharray':dash}:{}),...(opacity==null?{}:{'stroke-opacity':opacity})});
 const caption=(value,x,y,anchor,size,fill)=>{const node=svg('text');node.textContent=value;
  set(node,{x:round(x),y:round(y),'font-size':size||9,fill:fill||'#69746c'});if(anchor)node.setAttribute('text-anchor',anchor);return node;};
 const callout=(container)=>{const node=document.createElement('div');node.className='chart-callout';node.hidden=true;
  container.append(node);return node;};
 const place=(node,container,left,top)=>{node.style.left=left+'px';node.style.top=top+'px';};
 // QuotaChartTimeTickBuilder: natural hours inside a single-day window, local
 // midnights for multi-day windows, nothing past eight days.
 const gridTicks=(start,span)=>{
  const ticks=[];const end=start+span;
  if(span<=0)return ticks;
  if(span<=24*HOUR)for(let t=nextHour(start);t<end;t+=HOUR)ticks.push(t);
  else if(span<=8*DAY)for(let t=nextMidnight(start);t<end;t+=DAY)ticks.push(t);
  return ticks;
 };
 const sameDay=(a,b)=>Math.floor((a+tzOffset()*60000)/DAY)===Math.floor((b+tzOffset()*60000)/DAY);
 // MenuView axisTimeText / tooltipTimeText: drop the date inside the start day.
 const axisTime=t=>t==null?'':sameDay(t,axisTime.day)?hm(t):mh(t);
 // App 的 84pt 图表长在 296pt 菜单里，绘图区有 258pt。后台把它塞进模型列，
 // 绘图区窄到 190px 以下时网格线、底部 0 刻度和两端时间标签只剩噪声 ——
 // 窄图主动做减法，而不是把 296pt 的细节等比压扁。
 const NARROW=190;

 // SVG line+area chart of the remaining value over a reset window.
 // viewBox 与像素 1:1，容器变宽变窄时重绘，避免文字被拉伸。
 function curve(container,spec){
  const width=Math.max((container&&container.clientWidth)||296,160);
  const plot={x:FRAME.left,y:FRAME.top,w:Math.max(width-FRAME.left-FRAME.right,1),h:FRAME.height-FRAME.top-FRAME.bottom};
  const narrow=plot.w<NARROW;
  const start=Number(spec.windowStart)||0,end=Number(spec.windowEnd)||0,span=Math.max(end-start,0);
  const yMax=Number(spec.yMax)>0?Number(spec.yMax):100;
  const x=t=>round(plot.x+(span>0?clamp(t-start,0,span)/span:0)*plot.w);
  const y=v=>round(plot.y+plot.h-clamp(Number(v)||0,0,yMax)/yMax*plot.h);
  const root=svg('svg');
  set(root,{viewBox:`0 0 ${width} ${FRAME.height}`,width,height:FRAME.height,role:'img'});
  root.setAttribute('aria-label',spec.aria||'');
  // drawBackground: rounded plate behind the plot only.
  root.append(set(svg('rect'),{x:plot.x,y:plot.y,width:round(plot.w),height:round(plot.h),rx:7,ry:7,fill:'rgba(0,0,0,0.035)'}));
  // drawAxes: left + bottom rule, warning threshold, 100% / 0 labels.
  root.append(line(plot.x,plot.y,plot.x,plot.y+plot.h,'rgba(0,0,0,0.14)'),line(plot.x,plot.y+plot.h,plot.x+plot.w,plot.y+plot.h,'rgba(0,0,0,0.14)'));
  const threshold=Number(spec.warningThreshold);
  if(threshold>0&&threshold<100){
   const thresholdY=y(yMax*threshold/100);
   root.append(line(plot.x,thresholdY,plot.x+plot.w,thresholdY,'rgba(176,122,42,0.45)',1,'3,3'));
  }
  // 纵轴刻度右对齐贴在轴线左侧，不压进绘图区；基线分别落在绘图区的上下沿内侧，
  // 底下的 0 和左下角的时间标签就不会挤成「0 13:23」一串。窄列只留顶部一个。
  root.append(caption(yMax===100?'100%':String(Math.round(yMax)),plot.x-4,plot.y+8,'end',narrow?8:9));
  if(!narrow)root.append(caption('0',plot.x-4,plot.y+plot.h,'end',9));
  // drawTimeTicks：窄列里 4 条竖虚线 + 对角线 + 告警线会把绘图区划成碎块，直接不画。
  if(!narrow)for(const tick of gridTicks(start,span))root.append(line(x(tick),plot.y,x(tick),plot.y+plot.h,'rgba(0,0,0,0.10)',1,'2,3'));
  // drawPaceGuide: diagonal from a full quota at the window start to zero at the reset.
  // 窄图里它横穿整块绘图区，压到 0.3 只留暗示（节奏结论在元信息行里有文字）。
  if(spec.pace)root.append(line(plot.x,plot.y,plot.x+plot.w,plot.y+plot.h,spec.pace.ahead?TINT.green:TINT.red,1,'3,3',narrow?0.3:0.55));
  // drawSeries
  const points=(spec.points||[]).slice().sort((a,b)=>a.t-b.t).map(point=>({t:clamp(Number(point.t)||0,start,end),y:Number(point.y)||0}));
  const gradientID='aqb-grad-'+Math.random().toString(36).slice(2,8);
  if(points.length===1){
   const point=points[0];
   root.append(line(x(point.t),plot.y+plot.h,x(point.t),plot.y+plot.h,spec.tint,2,null,0.45));
   root.append(set(svg('circle'),{cx:x(point.t),cy:y(point.y),r:3,fill:spec.tint}));
  }else if(points.length>1){
   const defs=svg('defs'),gradient=svg('linearGradient');
   set(gradient,{id:gradientID,x1:0,y1:0,x2:0,y2:1});
   gradient.append(set(svg('stop'),{offset:0,'stop-color':spec.tint,'stop-opacity':0.22}),
    set(svg('stop'),{offset:1,'stop-color':spec.tint,'stop-opacity':0.03}));
   defs.append(gradient);root.append(defs);
   const d=`M ${points.map(p=>`${x(p.t)} ${y(p.y)}`).join(' L ')} L ${x(points[points.length-1].t)} ${plot.y+plot.h} L ${x(points[0].t)} ${plot.y+plot.h} Z`;
   root.append(set(svg('path'),{d,fill:`url(#${gradientID})`,stroke:'none'}));
   root.append(set(svg('polyline'),{points:points.map(p=>`${x(p.t)},${y(p.y)}`).join(' '),fill:'none',stroke:spec.tint,
    'stroke-width':2,'stroke-linecap':'round','stroke-linejoin':'round'}));
   for(const point of points)root.append(set(svg('circle'),{cx:x(point.t),cy:y(point.y),r:2,fill:spec.tint}));
  }
  if(spec.thresholdLabel)root.append(caption(`${Math.round(threshold)}%`,plot.x+2,y(yMax*threshold/100)-1,'start',7,'#b07a2a'));
  // drawTimeLabels：起止各一端，贴住绘图区的左右边。
  axisTime.day=start;
  root.append(caption(axisTime(start),plot.x,plot.y+plot.h+4,'start'),
   caption(axisTime(end),plot.x+plot.w,plot.y+plot.h+4,'end'));
  // drawHoveredGuide + ChartCallout
  const guide=line(plot.x,plot.y,plot.x,plot.y+plot.h,spec.tint,1,'4,4',0);
  const marker=set(svg('circle'),{cx:plot.x,cy:plot.y,r:4,fill:'#ffffff',stroke:spec.tint,'stroke-width':2,opacity:0});
  root.append(guide,marker);
  if(container)container.append(root);
  if(container&&points.length&&typeof container.addEventListener==='function'){
   container.style.position='relative';
   const tip=callout(container);
   const hide=()=>{tip.hidden=true;guide.setAttribute('stroke-opacity','0');marker.setAttribute('opacity','0');};
   container.addEventListener('mousemove',event=>{
    const bounds=typeof container.getBoundingClientRect==='function'?container.getBoundingClientRect():{left:0,top:0};
    const pointerX=event.clientX-bounds.left;
    if(pointerX<plot.x-8||pointerX>plot.x+plot.w+8){hide();return;}
    let nearest=points[0];
    for(const point of points)if(Math.abs(x(point.t)-pointerX)<Math.abs(x(nearest.t)-pointerX))nearest=point;
    guide.setAttribute('x1',x(nearest.t));guide.setAttribute('x2',x(nearest.t));guide.setAttribute('stroke-opacity','0.35');
    marker.setAttribute('cx',x(nearest.t));marker.setAttribute('cy',y(nearest.y));marker.setAttribute('opacity','1');
    tip.textContent=`${sameDay(nearest.t,start)?hm(nearest.t):mh(nearest.t)} · ${spec.tipValue?spec.tipValue(nearest.y):nearest.y}`;
    tip.hidden=false;
    // 气泡按容器宽度收边：窄列里 40px 的固定留白会把可移动范围压到几乎为零。
    const margin=Math.min(46,Math.max(width/2-10,10));
    place(tip,container,clamp(x(nearest.t),margin,Math.max(width-margin,margin)),Math.max(y(nearest.y)-20,0));
   });
   container.addEventListener('mouseleave',hide);
   redrawOnResize(container,()=>{container.replaceChildren();curve(container,spec);});
  }
  return root;
 }
 // 容器宽度变化时重画一次（图表是 1:1 像素映射，缩放会让字号变形）。
 function redrawOnResize(container,draw){
  if(typeof ResizeObserver!=='function'||typeof container.getBoundingClientRect!=='function')return;
  let last=container.clientWidth,timer=null;
  const observer=new ResizeObserver(()=>{
   if(container.clientWidth===last)return;
   last=container.clientWidth;
   clearTimeout(timer);
   timer=setTimeout(draw,120);
  });
  observer.observe(container);
 }

 // 柱宽由容器宽度反推，而不是另定一组档位：先按上限 16px 试，收窄到 3px 还放不下
 // 就丢掉最老的周期。好处是柱子条永远铺满整张卡片，密度是算出来的结果。
 // App 固定 10px 是因为菜单永远有 258pt 绘图区；后台的模型列宽度随模型数变。
 // 量不到宽度（隐藏容器／无 layout）时不裁剪，回到 App 的 10px。
 const GAP=2,MAX_BAR=16,MIN_BAR=3;
 const fit=(width,count)=>{
  if(!(width>0))return{bar:10,keep:count};
  const bar=Math.min(MAX_BAR,Math.floor((width-GAP*(count-1))/count));
  if(bar>=MIN_BAR)return{bar,keep:count};
  return{bar:MIN_BAR,keep:Math.max(1,Math.floor((width+GAP)/(MIN_BAR+GAP)))};
 };

 // Completed utilization cycles as mini columns (app ModelUtilizationBarsView):
 // 1 column per cycle, height = peak used%, track behind, hover label = left%.
 function cycleBars(container,spec){
  if(!container)return null;
  const all=(spec.cycles||[]).slice().sort((a,b)=>a.resetsAt-b.resetsAt);
  const plan=fit(container.clientWidth||0,all.length);
  const cycles=all.slice(-plan.keep);
  // 柱距不到 9px 时，悬停数字会盖住左右邻居 —— 交给整行的气泡去说。
  const inlineLabel=plan.bar>=9;
  const duration=Number(spec.cycleDuration)||0;
  container.style.position='relative';
  const row=document.createElement('div');row.className='cycle-row';
  Object.assign(row.style,{display:'flex',alignItems:'flex-end',justifyContent:'center',gap:GAP+'px',height:'30px'});
  const bars=cycles.map((cycle,index)=>{
   const leftPercent=clamp(100-cycle.peakPercent,0,100);
   const track=document.createElement('div');track.className='cycle-bar';
   Object.assign(track.style,{position:'relative',flex:'1',maxWidth:plan.bar+'px',minWidth:Math.min(plan.bar,3)+'px',height:'20px',
    borderRadius:'1.5px',background:'rgba(40,53,46,0.07)'});
   const fill=document.createElement('div');fill.className='cycle-fill';
   Object.assign(fill.style,{position:'absolute',left:'0',right:'0',bottom:'0',borderRadius:'1.5px',
    height:clamp(cycle.peakPercent,0,100)+'%',background:leftPercent>=100?TINT.secondary:spec.tint});
   const label=document.createElement('span');label.className='cycle-label';label.textContent=String(Math.round(leftPercent));
   track.append(fill);
   if(inlineLabel)track.append(label);
   track.setAttribute('title',spec.label?spec.label(cycle):cycleRange(cycle,index,cycles,duration));
   row.append(track);
   return track;
  });
  container.append(row);
  if(bars.length&&typeof container.addEventListener==='function'){
   const tip=callout(container);
   const hide=()=>{tip.hidden=true;};
   container.addEventListener('mousemove',event=>{
    const bounds=typeof container.getBoundingClientRect==='function'?container.getBoundingClientRect():{left:0};
    const pointerX=event.clientX-bounds.left;
    let best=0,bestDistance=Infinity;
    bars.forEach((bar,index)=>{const centre=bar.offsetLeft+bar.offsetWidth/2;const distance=Math.abs(centre-pointerX);
     if(distance<bestDistance){bestDistance=distance;best=index;}});
    tip.textContent=bars[best].getAttribute('title');
    tip.hidden=false;
    place(tip,container,clamp(bars[best].offsetLeft+bars[best].offsetWidth/2,44,Math.max(row.offsetWidth-44,44)),0);
   });
   container.addEventListener('mouseleave',hide);
  }
  return row;
 }
 // ModelUtilizationBarsView cycleTimeRangeText: date range for day-long cycles,
 // clock range for short ones.
 function cycleRange(cycle,index,cycles,duration){
  const end=cycle.resetsAt;
  let span=duration;
  if(!(span>0)){
   if(cycles[index-1])span=end-cycles[index-1].resetsAt;
   else if(cycles[index+1])span=cycles[index+1].resetsAt-end;
  }
  const start=end-Math.max(span,0);
  const left=String(Math.round(clamp(100-cycle.peakPercent,0,100)))+'%';
  if(span>=DAY)return start>0?`${md(start)}-${md(end)} · ${left}`:`${md(end)} · ${left}`;
  return sameDay(start,end)?`${hm(start)}-${hm(end)} · ${left}`:`${mh(start)}-${mh(end)} · ${left}`;
 }

 // Admin-only companion: consumption per UTC hour. Not part of the app menu,
 // rendered under an explicit label so the replica stays faithful.
 function hourlyBars(container,spec){
  if(!container)return null;
  const all=(spec.buckets||[]).slice().sort((a,b)=>a.hourStart-b.hourStart);
  const plan=fit(container.clientWidth||0,all.length);
  const buckets=all.slice(-plan.keep);
  const row=document.createElement('div');
  Object.assign(row.style,{display:'flex',alignItems:'flex-end',gap:GAP+'px',height:'30px',marginTop:'6px'});
  const column=(heightPercent,background,hover)=>{const bar=document.createElement('div');
   Object.assign(bar.style,{flex:'1',maxWidth:plan.bar+'px',minWidth:Math.min(plan.bar,3)+'px',
    height:heightPercent+'%',borderRadius:'1.5px',background});
   const title=document.createElement('title');title.textContent=hover;bar.append(title);
   // HTML <title> children only tooltip inside SVG; mirror the text onto the title attribute.
   bar.setAttribute('title',hover);return bar;};
  for(const bucket of buckets){
   const used=Math.round(bucket.consumedPercent);
   row.append(column(clamp(bucket.consumedPercent,0,100),bucket.consumedPercent>=80?TINT.orange:TINT.green,
    spec.label?spec.label(bucket):h0(bucket.hourStart)+' · '+(zh()?'耗 '+used+'%':'used '+used+'%')));
  }
  container.append(row);
  if(buckets.length){
   const line=document.createElement('div');
   Object.assign(line.style,{display:'flex',justifyContent:'space-between',fontSize:'9px',color:'#69746c',marginTop:'2px'});
   const first=document.createElement('span'),last=document.createElement('span');
   first.textContent=h0(buckets[0].hourStart);last.textContent=h0(buckets[buckets.length-1].hourStart+HOUR);
   line.append(first,last);container.append(line);
  }
  return row;
 }

 return {curve,cycleBars,hourlyBars,TINT};
})();
