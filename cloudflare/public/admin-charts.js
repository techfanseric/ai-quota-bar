// Pure rendering for the /admin quota cards, mirroring the macOS app's QuotaAreaChart
// and ModelUtilizationBarsView. No fetching, no state: admin.js owns the data and calls
// window.AdminQuotaCharts.curve / .cycleBars / .hourlyBars(container, spec).
// CSP-safe: no innerHTML, no <style> injection, no inline handlers; attributes via setAttribute.
window.AdminQuotaCharts=(()=>{
 const NS='http://www.w3.org/2000/svg',HOUR=3600000,DAY=86400000;
 const zh=()=>document.documentElement.lang.indexOf('zh')===0;
 const p2=n=>String(n).padStart(2,'0');
 const md=t=>{const d=new Date(t);return p2(d.getUTCMonth()+1)+'/'+p2(d.getUTCDate());};
 const hm=t=>{const d=new Date(t);return p2(d.getUTCHours())+':'+p2(d.getUTCMinutes());};
 const mh=t=>md(t)+' '+hm(t);
 const h0=t=>md(t)+' '+p2(new Date(t).getUTCHours())+':00';
 const clamp=(v,lo,hi)=>Math.min(hi,Math.max(lo,v));
 const round=n=>Math.round(n*100)/100;
 const set=(node,props)=>{for(const key in props)node.setAttribute(key,String(props[key]));return node;};
 const svg=tag=>document.createElementNS(NS,tag);
 const stroke=(x1,y1,x2,y2,color,width,dash,opacity)=>set(svg('line'),{x1,y1,x2,y2,stroke:color,'stroke-width':width,
  ...(dash?{'stroke-dasharray':dash}:{}),...(opacity==null?{}:{'stroke-opacity':opacity})});
 const caption=(text,x,y,anchor)=>{const node=svg('text');node.textContent=text;
  set(node,{x,y,'font-size':9,fill:'#69746c'});if(anchor)node.setAttribute('text-anchor',anchor);return node;};
 const dot=(x,y,r,tint)=>set(svg('circle'),{cx:x,cy:y,r,fill:tint});
 const barRow=()=>{const row=document.createElement('div');
  Object.assign(row.style,{display:'flex',alignItems:'flex-end',gap:'2px',height:'30px',marginTop:'6px'});return row;};
 const column=(heightPercent,background,hover)=>{const bar=document.createElement('div');
  Object.assign(bar.style,{flex:'1',maxWidth:'10px',minWidth:'3px',height:heightPercent+'%',borderRadius:'1.5px',background});
  const title=document.createElement('title');title.textContent=hover;bar.append(title);
  // HTML <title> children only tooltip inside SVG; mirror the text onto the title attribute.
  bar.setAttribute('title',hover);return bar;};

 // SVG line+area chart of remaining % (0-100) over a time window (app QuotaAreaChart).
 function curve(container,spec){
  const width=(container&&container.clientWidth)||320,top=8,bottom=78,left=30,right=width-8;
  const start=spec.windowStart,end=spec.windowEnd,span=Math.max(0,end-start);
  const x=t=>round(left+(span>0?(t-start)/span:0)*(right-left));
  const y=v=>round(bottom-clamp(Number(v)||0,0,100)/100*(bottom-top));
  const root=svg('svg');
  set(root,{viewBox:`0 0 ${width} 96`,width,height:96});
  root.append(set(svg('rect'),{x:0,y:0,width,height:96,rx:7,ry:7,fill:'rgba(0,0,0,0.035)'}));
  const id='aqb-grad-'+Math.random().toString(36).slice(2,8),defs=svg('defs'),gradient=svg('linearGradient');
  set(gradient,{id,x1:0,y1:0,x2:0,y2:1});
  gradient.append(set(svg('stop'),{offset:0,'stop-color':spec.tint,'stop-opacity':0.22}),
   set(svg('stop'),{offset:1,'stop-color':spec.tint,'stop-opacity':0.03}));
  defs.append(gradient);root.append(defs);
  root.append(stroke(left,top,left,bottom,'rgba(0,0,0,0.14)',1),stroke(left,bottom,right,bottom,'rgba(0,0,0,0.14)',1));
  root.append(caption('100%',2,top-1),caption('0',2,bottom+3));
  if(span>0&&span<=24*HOUR)for(let t=(Math.floor(start/HOUR)+1)*HOUR;t<end;t+=HOUR)
   root.append(stroke(x(t),top,x(t),bottom,'rgba(0,0,0,0.10)',1,'2,3'));
  else if(span>24*HOUR&&span<=8*DAY)for(let t=(Math.floor(start/DAY)+1)*DAY;t<end;t+=DAY)
   root.append(stroke(x(t),top,x(t),bottom,'rgba(0,0,0,0.10)',1,'2,3'));
  if(spec.pace)root.append(stroke(left,top,right,bottom,spec.pace.reserve?'#507a59':'#9b4a32',1,'3,3',0.55));
  const points=(spec.points||[]).slice().sort((a,b)=>a.t-b.t).map(point=>({t:clamp(point.t,start,end),y:point.y}));
  if(points.length===1){
   const point=points[0];
   root.append(stroke(x(point.t),top,x(point.t),bottom,spec.tint,2,null,0.45),dot(x(point.t),y(point.y),3,spec.tint));
  }else if(points.length>1){
   const d=`M ${points.map(p=>x(p.t)+' '+y(p.y)).join(' L ')} L ${x(points[points.length-1].t)} ${bottom} L ${x(points[0].t)} ${bottom} Z`;
   root.append(set(svg('path'),{d,fill:`url(#${id})`,stroke:'none'}));
   root.append(set(svg('polyline'),{points:points.map(p=>x(p.t)+','+y(p.y)).join(' '),fill:'none',stroke:spec.tint,
    'stroke-width':2,'stroke-linecap':'round','stroke-linejoin':'round'}));
   for(const point of points)root.append(dot(x(point.t),y(point.y),2,spec.tint));
  }
  const sameDay=Math.floor(start/DAY)===Math.floor(end/DAY),timeText=t=>sameDay?hm(t):mh(t);
  root.append(caption(timeText(start),left,86),caption(timeText(end),right,86,'end'));
  if(container)container.append(root);
  return root;
 }

 // Mini columns for completed utilization cycles (app ModelUtilizationBarsView).
 function cycleBars(container,spec){
  if(!container)return null;
  const row=barRow(),cycles=(spec.cycles||[]).slice().sort((a,b)=>a.resetsAt-b.resetsAt);
  for(const cycle of cycles){
   const leftPercent=Math.round(100-cycle.peakPercent);
   row.append(column(clamp(cycle.peakPercent,0,100),cycle.peakPercent>=100?'#8a948d':spec.tint,
    spec.label?spec.label(cycle):mh(cycle.resetsAt)+' · '+(zh()?'剩 '+leftPercent+'%':'left '+leftPercent+'%')));
  }
  container.append(row);
  return row;
 }

 // Mini columns for consumption per UTC hour (web-only companion to the cycle bars).
 function hourlyBars(container,spec){
  if(!container)return null;
  const row=barRow(),buckets=(spec.buckets||[]).slice().sort((a,b)=>a.hourStart-b.hourStart);
  for(const bucket of buckets){
   const used=Math.round(bucket.consumedPercent);
   row.append(column(clamp(bucket.consumedPercent,0,100),bucket.consumedPercent>=80?'#b07a2a':'#507a59',
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

 return {curve,cycleBars,hourlyBars};
})();
