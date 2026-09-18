// Fictional fixture following UsageHistory.month / last24Hours and UsageTokens.
export const DEMO_NOW = new Date(2026, 8, 18, 10, 24);
export function summarize(rows) {
 const total=rows.reduce((s,r)=>{for(const k of ['input','output','cached','records'])s[k]+=r[k];return s;},{input:0,output:0,cached:0,records:0});
 return {...total,tokens:total.input+total.output,cache:total.input?100*total.cached/total.input:null,cost:total.records?null:0};
}
export function usageFixture(account='all',now=DEMO_NOW) {
 const monthStart=new Date(now.getFullYear(),now.getMonth(),1),monthEnd=new Date(now.getFullYear(),now.getMonth()+1,1);
 const rows=[];
 for(let time=+monthStart,i=0;time<=+now;time+=300000,i++) {
  const date=new Date(time);if(date.getHours()<7||date.getHours()>22||i%7>2)continue;
  const scope=['current','current','previous','unknown'][i%4];if(account!=='all'&&scope!==account)continue;
  const input=200+(i%17)*120;rows.push({time,input,output:50+i%13*30,cached:Math.floor(input*(i%5)/5),records:1});
 }
 const bucket=(start,end)=>({start:new Date(start),end:new Date(end),...summarize(rows.filter(r=>r.time>=start&&r.time<end))});
 const daily=[];for(let d=new Date(monthStart);d<monthEnd;d.setDate(d.getDate()+1)){const next=new Date(d);next.setDate(next.getDate()+1);daily.push(bucket(+d,+next));}
 const hourly=Array.from({length:288},(_,i)=>bucket(+now-86400000+i*300000,+now-86400000+(i+1)*300000));
 return {daily,hourly,total:summarize(daily),recent:summarize(hourly),now,renewalDay:22};
}
export function intensity(value,maximum){return value==null?null:value<=0?0:Math.max(.25,Math.min(1,Math.ceil(value/Math.max(1,maximum)*4)/4));}
